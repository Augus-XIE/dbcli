local env=env
local db,grid=env.oracle,env.grid
local cfg=env.set

local ora=env.class(env.scripter)
function ora:ctor()
    self.db=env.oracle
    self.command="ora"
    self.help_title='Run SQL script under the "ora" directory. '
    self.script_dir,self.extend_dirs=env.WORK_DIR.."oracle"..env.PATH_DEL.."ora",{}
end

function ora:validate_accessable(name,options,values)
    local check_flag,expect_name,default,option,expect
    local db=self.db
    for i=1,#options do
        option=options[i]
        default=option
        if name:find("CHECK_USER",1,true)==1 then--check user
            check_flag=3
            expect_name="user"
            if db.props.db_user ~= option and option~="DEFAULT" then default=nil end
            expect=option
        elseif name:find("CHECK_ACCESS",1,true)==1 then--objects are sep with the / symbol
            check_flag=2
            expect_name="access"
            for obj in option:gmatch("([^/%s]+)") do
                if obj:upper()~="DEFAULT" and not db:check_access(obj,1) then
                    default=nil
                    expect='the accesses to: '.. option
                    break
                end
            end
        else--check version
            local check_ver=option:match('^([%d%.]+)$')
            if check_ver then
                check_flag=1
                expect_name="database version"
                local db_version=self:format_version(db.props.db_version or "8.0.0.0.0")
                if db_version<self:format_version(check_ver) then default=nil end
                expect=option
            end
        end
        if default~=nil then break end
    end

    if not default then
        env.raise("This command doesn't support current %s %s, expected as %s!",
            expect_name,
            check_flag==1 and (db.props.db_version or 'unkown')
                or check_flag==2 and "rights"
                or check_flag==3 and (db.props.db_user or 'unknown'),
            expect)
    end

    return default
end

local cache_obj={}
function db:check_obj(obj_name)
    local obj=obj_name and obj_name:upper()
    if obj and cache_obj[obj] then return cache_obj[obj] end
    db.C.ora:run_script('_find_object',obj_name,1)
    local args={
        target=obj_name,
        owner=env.var.get_input('OBJECT_OWNER'),
        object_type=env.var.get_input('OBJECT_TYPE'),
        object_name=env.var.get_input('OBJECT_NAME'),
        object_subname=env.var.get_input('OBJECT_SUBNAME'),
        object_id=env.var.get_input('OBJECT_ID')}
    if args.owner=='SYS' then
        local full_name=table.concat({args.owner,args.object_name,args.object_subname},'.')
        cache_obj[obj],cache_obj[args.object_name..(args.object_subname and ('.'..args.object_subname) or '')],cache_obj[full_name]=args,args,args
        args.alias_list={obj,full_name,args.object_name}
    end
    return args and args.object_id and args.object_id~='' and args
end

function db:check_access(obj_name,...)
    local o=obj_name and obj_name:upper()
    local obj=self:check_obj(obj_name,...)
    if not obj or not obj.object_id then return false end
    if cache_obj[o] and cache_obj[o].accessible then return cache_obj[o].accessible==1 and true or false end
    obj.count='#NUMBER'
    self:internal_call([[
        DECLARE
            x   PLS_INTEGER := 0;
            e   VARCHAR2(500);
            obj VARCHAR2(30) := :owner||'.'||:object_name;
        BEGIN
            IF instr(obj,'PUBLIC.')=1 THEN
                obj := :object_name;
            END IF;
            BEGIN
                EXECUTE IMMEDIATE 'select count(1) from ' || obj || ' where rownum<1';
                x := 1;
            EXCEPTION WHEN OTHERS THEN NULL;
            END;

            IF x = 0 THEN
                BEGIN
                    EXECUTE IMMEDIATE 'begin ' || obj || '."_test_access"; end;';
                    x := 1;
                EXCEPTION
                    WHEN OTHERS THEN
                        e := SQLERRM;
                        IF INSTR(e,'PLS-00225')>0 OR INSTR(e,'PLS-00302')>0 THEN
                            x := 1;
                        END IF;
                END;
            END IF;
            :count := x;
        END;
    ]],obj)
    if cache_obj[o] then
        local value=obj.count==1 and 1 or 0
        for k,v in ipairs(cache_obj[o].alias_list) do cache_obj[v].accessible=value end
    end
    return obj.count==1 and true or false;
end

function ora.onreset()
    cache_obj={}
end

function ora.onload()
    env.event.snoop("AFTER_ORACLE_CONNECT",ora.onreset)
end

return ora.new()