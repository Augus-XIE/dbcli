local env=env
local snap={script_dir=env.WORK_DIR.."oracle"..env.PATH_DEL.."snap"}
local db,sleep,math,cfg=env.oracle,env.sleep,env.math,env.set
local script_dir=env.WORK_DIR..'oracle'..env.PATH_DEL..'snap'..env.PATH_DEL

function snap.rehash()
	snap.cmdlist=db.C.ora.rehash(snap.script_dir,'snap')
end

function snap.fetch(cmd,pos)
	local row
	local grp_idx,idx=cmd.grp_idx,{}
	local counter
	local rs=cmd['rs'..pos]
	while true do 
		row=db.resultset:fetch(rs)
		if not row then
			cmd['rs'..pos]=nil
			return coroutine.yield(cmd.name,0)
		end
		counter=0
		for k,_ in pairs(grp_idx) do
			counter=counter+1
			idx[counter]=row[k] or ""
		end		
		coroutine.yield(cmd.name,pos,table.concat(idx,'\1'),row)
	end
end

function snap.parse(name) 
	local file=snap.cmdlist[name].path
	local f=io.open(file)
	if not f then
		return print("Cannot find open file "..file)
	end

	local txt=loadstring(('return '..f:read("*a")):gsub(db.C.ora.comment,"",1))

	if not txt then
	   return print("Invalid syntax in "..file)
	end

	local cmd={}
	for k,v in pairs(txt()) do
		cmd[tostring(k):lower()]=v
	end
	
	for _,k in ipairs({"sql","agg_cols"}) do
		if not cmd[k] then
			return print("Cannot find key '"..k.."'' in "..file)
		end
	end

	cmd.grp_cols=cmd.grp_cols and (','..cmd.grp_cols:upper()..',') or nil
	cmd.agg_cols=','..cmd.agg_cols:upper()..','	
	cmd.name=name

	return cmd
end

function snap.after_exec()
	cfg.restore()
	db.internal_exec=false
	db:commit()
	db:internal_call("ALTER SESSION SET ISOLATION_LEVEL=READ COMMITTED")	
end

function snap.exec(interval,typ,...)
	if not snap.cmdlist or interval=="-r" or interval=="-R" then
		snap.rehash(snap.script_dir)		
	end

	if not interval then
		return env.helper.helper("SNAP")
	end	

	interval=interval:upper()
	if interval:sub(1,1)=='-' then
		if interval=="-H" then
			env.helper.helper("SNAP",typ)
		elseif interval=="-S" then
			env.helper.helper("SNAP","-S",...)
		end
		return
	end

	if not tonumber(interval) or not typ then
		return print("please set the interval and snap names.")
	end

	local args={...}
	for i=1,9 do
		args["V"..i]=args[i] or ""
	end
	
	local cmds={}

	for v in typ:gmatch("([^\n\t%s,]+)") do
		v=v:upper()
		if not snap.cmdlist[v] then
			return print("Error: Cannot find snap command :" .. v)
		end
		local cmd=snap.parse(v)
		if not cmd then return end
		cmds[v]=cmd
	end		

	cfg.backup()	
	cfg.set("AUTOCOMMIT","off")
	cfg.set("digits",2)
	local clock=os.clock()
	db.internal_exec=true
	local get_time="select to_char(sysdate,'yyyy-mm-dd hh24:mi:ss') from dual "
	local start_time=db:get_value(get_time)
	db:internal_call("ALTER SESSION SET ISOLATION_LEVEL=SERIALIZABLE")
	for _,cmd in pairs(cmds) do
		cmd.rs2=db:internal_call(cmd.sql,args)
	end
	db:commit()
	
	sleep(interval+clock-os.clock())
	--sleep(interval)
	local end_time=db:get_value(get_time)
	for _,cmd in pairs(cmds) do
		cmd.rs1=db:internal_call(cmd.sql,args)
	end
	db:commit()	
	db:internal_call("ALTER SESSION SET ISOLATION_LEVEL=READ COMMITTED")
	local title="\nSnapping %s from "..start_time.." to "..end_time.." :\n"..string.rep("=",80)
	local result={}
	local cos={}
	for name,cmd in pairs(cmds) do		
		cmd.agg_idx,cmd.grp_idx={},{}
		cmd.title=db.resultset:fetch(cmd.rs1),db.resultset:fetch(cmd.rs2)
		for i,k in ipairs(cmd.title) do
			if cmd.agg_cols:find(','..k:upper()..',',1,true) then
				cmd.agg_idx[i]=true
				cmd.title[i]='*'..k
			elseif not cmd.grp_cols or cmd.grp_cols:find(','..k:upper()..',',1,true) then
				cmd.grp_idx[i]=true
			end
		end
		result[name]={}
		cmd.grid=grid.new()
		cmd.grid:add(cmd.title)
		table.insert(cos,coroutine.create(function() snap.fetch(cmd,1) end))
		table.insert(cos,coroutine.create(function() snap.fetch(cmd,2) end))
	end
	
	while #cos>0 do
		local succ,rtn,pos,key,value
		for k=#cos,1,-1 do
			succ,name,pos,key,row=coroutine.resume(cos[k])
			local agg_idx=name and cmds[name].agg_idx
			if not row then
				table.remove(cos,k)								
			else
				if not result[name][key] then result[name][key]={} end
				value=result[name][key]
				if not value[pos] then
					value[pos]=row
					if pos==1 then
						cmds[name].grid:add(row)
					end
				else
					for k,_ in pairs(agg_idx) do
						if tonumber(value[pos][k]) or tonumber(row[k]) then
							value[pos][k]= math.round((tonumber(value[pos][k]) or 0)+(tonumber(row[k]) or 0),2)
						end
					end
				end
				if value[1] and value[2] then
					for k,_ in pairs(agg_idx) do
						if tonumber(value[1][k]) and value[2][k] then							
							value[1][k]=math.round(value[1][k]-value[2][k],2)
						end
					end					
					result[name][key][2]=nil
				end
			end
		end
	end
		
	for name,cmd in pairs(cmds) do
		local idx=""
		for i,_ in pairs(cmd.agg_idx) do
			idx=idx..(-i)..','
			cmd.grid:add_calc_ratio(i)		
		end
		cmd.grid:sort(idx,true)		
		cfg.set("PrintSize",cfg.get("snaprows"))
		print(title:format(name))
		cmd.grid:print()		
	end
	
end

local help_ind=0
function snap.helper(_,cmd,search_key)	
	local help='Calculate a period of db/session performance/waits. Usage: snap <interval> <name1[,name2...]] [args] | -r | -s \nAvailable commands:\n=================\n'
	help_ind=help_ind+1
	if help_ind==2 and not snap.cmdlist then
		snap.exec('-r')
	end
	return env.helper.get_sub_help(cmd,snap.cmdlist,help,search_key)	
end

cfg.init("snaprows","50",nil,"oracle","Number of max records for the 'snap' command result"," 10 - 3000")

env.set_command(nil,"snap",snap.helper,{snap.exec,snap.after_exec},false,9)
return snap