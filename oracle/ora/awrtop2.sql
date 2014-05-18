WITH qry as (SELECT nvl(upper(:V1),'A') inst,
                    nullif(lower(:V2),'a')||'%' sqid,
                    nvl(lower(:V3),'total') calctype,
                    to_timestamp(nvl(:V4,to_char(sysdate-7,'YYMMDDHH24MI')),'YYMMDDHH24MI') st,
                    to_timestamp(coalesce(:V5,''||(:V4+1),to_char(sysdate,'YYMMDDHH24MI')),'YYMMDDHH24MI') ed,
                    lower(nvl(:V6,'ela')) sorttype
             FROM Dual) 
SELECT sql_id,
       plan_hash,
       last_call,
       lpad(replace(to_char(exe,decode(sign(exe - 1e5),-1,'fm99990','fm0.00EEEE')),'+0'),7) execs,
       lpad(replace(to_char(LOAD,decode(sign(LOAD - 1e5),-1,'fm99990','fm0.00EEEE')),'+0'),7) loads,
       lpad(replace(to_char(parse,decode(sign(parse - 1e5),-1,'fm99990','fm0.00EEEE')),'+0'),7) parses,
       lpad(replace(to_char(mem,decode(sign(mem - 1e5),-1,'fm99990.09','fm0.00EEEE')),'+0'),7) memory,
       lpad(replace(to_char(ela,decode(sign(ela - 1e5),-1,'fm99990.09','fm0.00EEEE')),'+0'),7) elapsed,
       lpad(replace(to_char(CPU,decode(sign(CPU - 1e5),-1,'fm99990.09','fm0.00EEEE')),'+0'),7) CPU_TIM,
       lpad(replace(to_char(iowait,decode(sign(iowait - 1e5),-1,'fm99990.09','fm0.00EEEE')),'+0'),7) io_wait,
       lpad(replace(to_char(ccwait,decode(sign(ccwait - 1e5),-1,'fm99990.09','fm0.00EEEE')),'+0'),7) cc_wait,
       lpad(replace(to_char(ccwait,decode(sign(clwait - 1e5),-1,'fm99990.09','fm0.00EEEE')),'+0'),7) cl_wait,
       lpad(replace(to_char(PLSQL,decode(sign(PLSQL - 1e5),-1,'fm99990.09','fm0.00EEEE')),'+0'),7) "PL/SQL",
       lpad(replace(to_char(JAVA,decode(sign(JAVA - 1e5),-1,'fm99990.09','fm0.00EEEE')),'+0'),7) JAVA_TM,
       lpad(replace(to_char(READ,decode(sign(READ - 1e5),-1,'fm99990.09','fm0.00EEEE')),'+0'),7) READS,
       lpad(replace(to_char(WRITE,decode(sign(WRITE - 1e5),-1,'fm99990.09','fm0.00EEEE')),'+0'),7) WRITES,
       lpad(replace(to_char(FETCH,decode(sign(FETCH - 1e5),-1,'fm99990.09','fm0.00EEEE')),'+0'),7) FETCHS,
       lpad(replace(to_char(RWS,decode(sign(RWS - 1e5),-1,'fm99990.09','fm0.00EEEE')),'+0'),7) "ROWS",
       lpad(replace(to_char(PX,decode(sign(PX - 1e5),-1,'fm99990.09','fm0.00EEEE')),'+0'),7) PX_SVRS
FROM   (SELECT sql_id,
               plan_hash,
               to_char(lastest,'YYYYMMDDHH24') last_call,
               exe,
               LOAD,
               parse,
               mem / exe1 mem,
               ela / exe1 ela,
               CPU / exe1 CPU,
               iowait / exe1 iowait,
               ccwait / exe1 ccwait,
               clwait / exe1 clwait,
               PLSQL / exe1 PLSQL,
               JAVA / exe1 JAVA,
               READ / exe1 READ,
               WRITE / exe1 WRITE,
               FETCH / exe1 FETCH,
               RWS / exe1 RWS,
               PX / exe1 PX,
               row_number() over(order by decode(sorttype, 'exe', exe, 'load', load, 'parse', parse, 'mem', mem, 'ela', ela, 'cpu', cpu, 'io', iowait, 'plsql', plsql, 'java', java, 'read', read, 'write', write, 'fetch', fetch, 'rws', rws, 'px', px,'cc',ccwait) desc nulls last) r
        FROM   (SELECT sql_id,
                       plan_hash_value plan_hash,
                       qry.sorttype,
                       MAX(begin_interval_time) lastest,
                       SUM(executions_delta) exe,
                       SUM(LOADS_DELTA) LOAD,
                       SUM(PARSE_CALLS_DELTA) parse,
                       AVG(sharable_mem/1024/ 1024) mem,
                       SUM(elapsed_time_delta * 1.67e-8) ela,
                       SUM(cpu_time_delta * 1.67e-8) CPU,
                       SUM(iowait_delta * 1.67e-8) iowait,
                       SUM(CCWAIT_DELTA * 1.67e-8) ccwait,
                       SUM(CLWAIT_DELTA * 1.67e-8) clwait,
                       SUM(PLSEXEC_TIME_DELTA * 1.67e-8) PLSQL,
                       SUM(JAVEXEC_TIME_DELTA * 1.67e-8) JAVA,
                       SUM(disk_reads_delta + hs.buffer_gets_delta)* 8 / 1024 READ,
                       SUM(direct_writes_delta)* 8 / 1024 WRITE,
                       SUM(END_OF_FETCH_COUNT_DELTA) FETCH,
                       SUM(ROWS_PROCESSED_DELTA) RWS,
                       SUM(PX_SERVERS_EXECS_DELTA) PX,
                       decode(qry.calctype,
                              'avg',
                              SUM(NVL(NULLIF(executions_delta, 0),
                                      NULLIF(PARSE_CALLS_DELTA, 0))),
                              1) exe1
                FROM   qry,dba_hist_snapshot s, Dba_Hist_Sqlstat hs
                WHERE  s.snap_id = hs.snap_id
                AND    s.instance_number = hs.instance_number
                AND    s.dbid = hs.dbid
                AND    hs.sql_id like qry.sqid
                AND    s.begin_interval_time between qry.st and ed
                AND    (qry.inst in('A','0') or qry.inst= ''||s.instance_number)
                GROUP  BY sql_id, plan_hash_value,qry.sorttype))
WHERE  r <= 50