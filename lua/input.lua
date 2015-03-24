local string,io,table=string,io,table
local dir=debug.getinfo(1).short_src:gsub('%w+%.lua','?.lua')
package.path=dir
io.stdout:write("    ------------------------------------------------------------------------------------------------------------------------\n")
io.stdout:write("    | RDBMS utility(DBCLI), type 'help' for more information. (c)2014-2015 hyee, MIT license(https://github.com/hyee/dbcli)|\n")
io.stdout:write("    ========================================================================================================================\n\n")

local env=require("env")
env.onload(...)  

--start the CLI interpretor

local line,eval,prompt = "",env.eval_line
local reader=reader
local history=reader:getHistory()
local ansi=env.ansi
local color=ansi and ansi.get_color or function() return "";end
reader:setExpandEvents(false)
local prompt_color="%s%s"..color("NOR").."%s"

local write=function(str)
    str=prompt_color:format(color("PROMPTCOLOR"),str,color("COMMANDCOLOR"))
    if prompt~=str then
        prompt=str
        reader:setPrompt(str)
    end
end

local os,clock=os
local stack=nil
while true do  
    if env.CURRENT_PROMPT=="_____EXIT_____" then break end    
    write(env.CURRENT_PROMPT)
    line = reader:readLine()  
    if not line or line:lower() == 'quit' or line:lower() == 'exit' then
        print("Exited.")
        env.unload()        
        os.exit(1) 
    end

    clock=os.clock()
    eval(line)
    if env.CURRENT_PROMPT==env.MTL_PROMPT and not stack then
        stack={line}
        pcall(history.removeLast,history)
        reader:setHistoryEnabled(false)
    elseif stack then
        if not line:find('^[%s\t]*$') then stack[#stack+1]=line end
        if env.CURRENT_PROMPT==env.PRI_PROMPT then
            if #stack==2 and line:find('^'..env.END_MARKS[1]..'[%s\t]*$') then
                history:add(java.cast(stack[1]..line,'java.lang.String',true))
                history:moveToEnd()
            end
            reader:setHistoryEnabled(true)
            stack=nil
        end
    end
    
    if env.PRI_PROMPT=="TIMING> " and env.CURRENT_PROMPT~=env.MTL_PROMPT then
        env.CURRENT_PROMPT=string.format('%06.2f',os.clock()-clock)..'> '
        env.MTL_PROMPT=string.rep(' ',#env.CURRENT_PROMPT)    
    end
end
