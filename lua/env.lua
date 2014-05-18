--init a global function to store CLI variables
local _G = _ENV or _G
local env=setmetatable({},{
    __call =function(self, key, value)            
            rawset(self,key,value) 
            _G[key]=value
        end,
    __index=function(self,key) return _G[key] end,
    __newindex=function(self,key,value) self(key,value) end
})
_G['env']=env

--Build command list
env._CMDS=setmetatable({___ABBR___={}},{
    __index=function(self,key) return self.___ABBR___[key] and self[self.___ABBR___[key]]  or nil end
})

--
env.space="    "
local _CMDS=env._CMDS
function env.list_dir(file_dir,file_ext,text_macher)
    local dir
    local keylist={}

    local filter=file_ext and "*."..file_ext or "*"
    file_dir=(file_dir..env.PATH_DEL):gsub("[\\/]+",env.PATH_DEL)
    if env.OS=="windows" then
        dir=io.popen('dir "'..file_dir..'\\'..filter..'" /b /s')
    else
        dir=io.popen('find "'..file_dir..'" -iname '..filter..' -print')
    end

    for n in dir:lines() do 
        local name=n:match("([^\\/]+)$")
        if file_ext then
            name=name:match("(.+)%.%w+$")
        end 
        local comment
        if  text_macher then  
            local f=io.open(n)
            if f then
                local txt=f:read("*a")
                f:close()
                if type(text_macher)=="string" then
                    comment=txt:match(text_macher) or ""
                elseif type(text_macher)=="function" then
                    comment=text_macher(txt) or ""      
                end
            end
        end
        keylist[#keylist+1]={name,n,comment}
    end
    
    return keylist
end

function env.set_command(obj,cmd,help_func,call_func,is_multiline,paramCount,dbcmd)
    local abbr={}
    if not paramCount then
        error("Incompleted command["..cmd.."], number of parameters is not defined!")
    end

    if type(cmd)=="table" then
        local tmp=cmd[1]:upper()
        for i=2,#cmd,1 do 
            if _CMDS[tmp] then break end
            cmd[i]=cmd[i]:upper()
            if _CMDS.___ABBR___[cmd[i]] then
                error("Command '"..cmd[i].."' is already defined in ".._CMDS[_CMDS.___ABBR___[cmd[i]]]["FILE"])
            end
            table.insert(abbr,cmd[i])
            _CMDS.___ABBR___[cmd[i]]=tmp          
        end
        cmd=tmp
    else
        cmd=cmd:upper()
    end
    
    if _CMDS[cmd] then
        error("Command '"..cmd.."' is already defined in ".._CMDS[cmd]["FILE"])
    end

    local src=env.callee()
    local desc=help_func
    local args= obj and {obj,cmd} or {cmd}
    if type(help_func) == "function" then
        desc=help_func(table.unpack(args))
    end

    if desc then
        desc = desc:gsub("^[\n\r%s\t]*[\n\r]+","")
        desc = desc:match("([^\n\r]+)") 
    end

    if is_multiline==true then
        is_multiline=function(cmd,other_parts)
            local p1=';+[%s\t\n]*$'
            local p2='\n[%s\t\n]*/[%s\t]*$'
            local match = (other_parts:match(p1) and 1) or (other_parts:match(p2) and 2) or false
            --print(match,other_parts)
            if not match then
                return false,other_parts
            end
            return true,other_parts:gsub(match==1 and p1 or p2,"")
        end
    end
    
    _CMDS[cmd]={
        OBJ    = obj,          --object, if the connected function is not a static function, then this field is used.
        FILE   = src,          --the file name that defines & executes the command
        DESC   = desc,         --command short help without \n
        HELPER = help_func,    --command detail help, it is a function
        FUNC   = call_func,    --command function        
        MULTI  = is_multiline,
        ABBR   = table.concat(abbr,','),
        ARGS   = paramCount,
        DBCMD  = dbcmd
    }
end

function env.callee()
    local info=debug.getinfo(3)    
    return info.short_src:sub(#env.WORK_DIR+1):gsub("%.%w+$","#"..info.currentline)
end

function env.exec_command(cmd,params)
    local clock,result=os.clock()
    name=cmd:upper()
    cmd=_CMDS[cmd]
    if not cmd then
        return print("No such comand["..name.." "..table.unpack(params).."]!")
    end

    if not cmd.FUNC then return end
    env.CURRENT_CMD=name
    local args= cmd.OBJ and {cmd.OBJ,table.unpack(params)} or {table.unpack(params)}
    local event=env.event and env.event.callback
    if event then event("BEFORE_COMMAND",name,params) end
    --env.trace.enable(true)
    local funs=type(cmd.FUNC)=="table" and cmd.FUNC or {cmd.FUNC}
    for _,func in ipairs(funs) do
        res = {pcall(func,table.unpack(args))}

        if not res[1] then
            result=res
            local msg={} 
            for v in tostring(res[2]):gmatch("(%u%u%u+%-[^\n\r]*)") do
                table.insert(msg,v)
            end
            if #msg > 0 then
                print(table.concat(msg,'\n'))
            else
                local trace=tostring(res[2]) --..'\n'..env.trace.enable(false)
                io.stderr:write(trace.."\n")
            end
        elseif not result then
            result=res       
        end

    end

    if result[1] and event then event("AFTER_COMMAND",name,params) end
    env.COMMAND_COST=os.clock()-clock
    if env.PRI_PROMPT=="TIMING> " then
        env.CURRENT_PROMPT=string.format('%06.2f',env.COMMAND_COST)..'> '
        env.MTL_PROMPT=#env.CURRENT_PROMPT
    end
    return table.unpack(result)
end



local is_in_multi_state=false
local curr_stmt=""
local multi_cmd

function env.set_prompt(default,continue)
    env.PRI_PROMPT,env.MTL_PROMPT=default:upper().."> ",continue or (" "):rep(#default+2)
    env.CURRENT_PROMPT=env.PRI_PROMPT
    return default:upper()
end


function env.pending_command()
    if curr_stmt and curr_stmt~="" then 
        return true
    end
end

function env.eval_line(line,exec)
    local b=line:byte()
    --remove bom header
    if not b or b>=128 then return end
    local done
    local function check_multi_cmd(lineval)
        curr_stmt = curr_stmt ..lineval
        done,curr_stmt=_CMDS[multi_cmd].MULTI(multi_cmd,curr_stmt)
        if done then  
            if curr_stmt then
                curr_stmt = (_CMDS[multi_cmd].ARGS == 1 and multi_cmd.." " or "")..curr_stmt
                local stmt={multi_cmd,curr_stmt}
                multi_cmd,curr_stmt=nil,nil
                env.CURRENT_PROMPT=env.PRI_PROMPT
                if exec~=false then 
                    env.exec_command(stmt[1],{stmt[2]})
                else
                    return stmt[1],{stmt[2]}
                end
            end
            multi_cmd,curr_stmt=nil,nil
            return
        end
        curr_stmt = curr_stmt .."\n"
        return multi_cmd
    end

    if not line then return end

    if multi_cmd then      
        return check_multi_cmd(line)
    end
    
    local cmd,rest=line:match('([^%s\n\r\t;]+)[%s\n\r\t]*(.*)')

    if not cmd or cmd=="" or cmd:sub(1,2)=="--" then return end
    if cmd:sub(1,2)=="/*" then cmd=cmd:sub(1,2) end
    cmd=cmd:upper()
    if not (_CMDS[cmd]) then
        return print("No such command["..cmd.."], please type 'help' for more information.")        
    elseif _CMDS[cmd].MULTI then --deal with the commands that cross-lines
        multi_cmd=cmd
        env.CURRENT_PROMPT=env.MTL_PROMPT
        curr_stmt = ""
        return check_multi_cmd(rest)
    end

    --deal with the single-line commands
    local args ,args1={}
    rest=rest:gsub("[;%s]+$","")
    if _CMDS[cmd].ARGS == 1 then
        table.insert(args,cmd.." "..rest)
    elseif _CMDS[cmd].ARGS == 2 then
        table.insert(args,rest)
    elseif rest then 
        local piece=""
        local quote='"'
        local is_quote_string = false
        for i=1,#rest,1 do
            local char=rest:sub(i,i)
            if is_quote_string then                
                if char ~= quote then
                    piece = piece .. char
                elseif (rest:sub(i+1,i+1) or " "):match("^%s*$") then
                    --end of a quote string if next char is a space
                    table.insert(args,piece:sub(2))
                    piece=''
                    is_quote_string=false
                else
                    piece=piece..char
                end
            else
                if char==quote and piece == '' then
                    --begin a quote string, if its previous char is not a space, then bypass
                    is_quote_string = true
                    piece=quote                   
                elseif not char:match("%s") then
                    piece = piece ..char
                elseif piece ~= '' then
                    table.insert(args,piece)    
                    piece=''
                end
            end
            if #args>=_CMDS[cmd].ARGS-2 then
                piece=rest:sub(i+1)
                if piece:sub(1,1)==quote and piece:sub(-1)==quote then
                    piece=piece:sub(2,-2)
                end
                table.insert(args,piece) 
                piece=""
                break
            end
        end
        --If the quote is not in couple, then treat it as a normal string
        if piece:sub(1,1)==quote then
            for s in piece:gmatch('([^%s]+)') do
                table.insert(args,s)
            end
        elseif piece~='' then
            table.insert(args,piece)
        end   
    end
    --print('Command:',cmd,table.concat (args,','))
    if exec~=false then
        env.exec_command(cmd,args)        
    else
        return cmd,args
    end
end

function env.testcmd(...)
    local args,cmd={...}
    for k,v in pairs(args) do
        if v:find(" ") and not v:find('"') then
            args[k]='"'..v..'"'
        end
    end
    cmd,args=env.eval_line(table.concat(args,' ')..';',false)
    if not cmd then return end
    print("Command    : "..cmd.."\nParameters : "..#args..' - '..(_CMDS[cmd].ARGS-1).."\n============================")
    for k,v in ipairs(args) do
        print(string.format("%-2s = %s",k,v))
    end
end

function env.onload(...)
    env.args={...} 
    env.init=require("init")     
    env.init.init_path()
    for k,v in ipairs({'jit','ffi','bit'}) do
        if not _G[v] then
            local m=package.loadlib("lua5.1."..(env.OS=="windows" and "dll" or "so"), "luaopen_"..v)()
            if not _G[v] then _G[v]=m end
            if v=="jit" then
                table.new=require("table.new")
                table.clear=require("table.clear")
                jit.profile=require("jit.profile")
            end
        end 
    end

    os.setlocale('',"all")
    env.set_prompt("SQL")  
    env.set_command(nil,"RELOAD","Reload environment, including variables, modules, etc",env.reload,false,1)
    env.set_command(nil,"LUAJIT","#Switch to luajit interpreter",function() os.execute(('"%sbin%sluajit"'):format(env.WORK_DIR,env.PATH_DEL)) end,false,1)
    env.set_command(nil,"-P","#Test parameters. Usage: -p <command> [<args>]",env.testcmd,false,99)
    env.init.load(init.module_list,env)
    env.set.init("Prompt","SQL",function(name,value) return env.set_prompt(value) end,"core","Define interpreter's command prompt, a special value is 'timing' to record the time cost for each command. ")
    if env.event then env.event.callback("ON_ENV_LOADED") end
    --load initial settings
    local ini_file=env.WORK_DIR.."data"..env.PATH_DEL.."init.cfg"
    local f=io.open(ini_file,"r")
    if f then
        for line in f:lines() do
            if not line:match('[%s\t]^#') then
                env.eval_line(line..';')
            end
        end
    else
        f=io.open(ini_file,'w')
        f:write("#Input initial setting in this file, which is loaded when the CLI starts\n")
    end

    f:close()

    for _,v in ipairs(env.args) do
        if v:sub(1,2) == "-D" then
            local key=v:sub(3):match("^([^=]+)")
            local value=v:sub(4+#key)
            java.system:setProperty(key,value)
        else
            env.eval_line(v:gsub("="," ",1)..';')
        end
    end 
end

function env.unload()
    if env.event then env.event.callback("ON_ENV_UNLOADED") end
    env.init.unload(init.module_list,env)
    env.init=nil
    package.loaded['init']=nil
    for k,v in pairs(_CMDS) do
        _CMDS[k]=nil
    end
    _CMDS.___ABBR___={}
    if jit and jit.flush then pcall(jit.flush) end
end

function env.reload() 
    print("Reloading environemnt ...")
    env.unload()
    env.onload(table.unpack(env.args))
end

return env