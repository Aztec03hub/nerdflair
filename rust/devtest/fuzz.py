import json, random, os, sys
out = sys.argv[1]; n = int(sys.argv[2]); random.seed(int(sys.argv[3]))
os.makedirs(out, exist_ok=True)
FIX="@FIX@"
dirs=[FIX+"/work/my-project",FIX+"/work/clean-repo",FIX+"/work/wrapper",FIX+"/work/single-wrapper",
      FIX+"/work/plain-dir","@HOME@",FIX+"/work/nope",""]
models=[{"display_name":"Opus 4.8 (1M context)","id":"claude-opus-4-8"},{"display_name":"Sonnet 4.5"},
        {"id":"claude-haiku-4-5-20250101"},"claude-fable-2-1","Opus 5",{"id":"weird-model-x9"},
        {},None,{"display_name":"Sonnet 4.5 (1M context)","id":"x"}]
styles=[None,{"name":"default"},{"name":"Explanatory"},{"name":"Learning"},{"name":"Proactive"},{"name":"Zebra"}]
efforts=[None,{"level":"low"},{"level":"medium"},{"level":"high"},{"level":"xhigh"},{"level":"max"}]
variants=["default","compact","minimal","mono","muted","compact-mono","fixedwidth","volzero","randomchime","volhalf","compact-volzero"]
for i in range(n):
    o={}
    o["workspace"]={"current_dir":random.choice(dirs)}
    if random.random()<0.85: o["workspace"]["project_dir"]=random.choice(dirs)
    m=random.choice(models)
    if m is not None: o["model"]=m
    if random.random()<0.9:
        weird=[ "abc","1.5","3abc","", "0x20", " 42 ", "-5", "1e3", None, True]
        o["cost"]={"total_cost_usd":random.choice([0,0.0001,0.004,0.125,round(random.uniform(0,50),6),round(random.uniform(0,2000),6),"2.50","abc",93.0]),
                   "total_duration_ms":random.choice([0,1000,119999,120001,900000,3599000,3600000,99999999]+weird),
                   "total_api_duration_ms":random.choice([0,999,1000,60000,412000,7200000]+weird)}
        o["cost"]={k:v for k,v in o["cost"].items() if v is not None}
    if random.random()<0.9:
        pctv=random.choice([0,1,5,40,79,80,81,99,100,random.randint(0,100),round(random.uniform(0,100),1),
                            "42","abc","55.0","1.5",93.0,"high"])
        o["context_window"]={"used_percentage":pctv,"total_input_tokens":random.randint(0,900000),
                             "total_output_tokens":random.randint(0,300000),
                             "context_window_size":random.choice([200000,1000000,500,0,"200000","zzz","2.5e5"])}
    if random.random()<0.8: o["session_id"]=random.choice(["sess-fixed-0001","sess-other-9","x/y z","\u00e9\u00e8-caf\u00e9",""])
    s=random.choice(styles)
    if s: o["output_style"]=s
    e=random.choice(efforts)
    if e: o["effort"]=e
    if random.random()<0.4: o["thinking"]={"enabled":random.choice([True,False])}
    if random.random()<0.3: o["fast_mode"]=random.choice([True,False])
    if random.random()<0.3: o["worktree"]={"branch":random.choice(["wt/x","feature/really-long-worktree-branch-name-abcdef","","br\u00e4nch-\u00fcnicode","a"*90])}
    if random.random()<0.4:
        o["rate_limits"]={}
        if random.random()<0.8: o["rate_limits"]["five_hour"]={"used_percentage":random.choice([round(random.uniform(0,100),1),"abc","60","85.0",0]),"resets_at":random.choice([1000,2000000000,9999999999,"soon",""])}
        if random.random()<0.8: o["rate_limits"]["seven_day"]={"used_percentage":random.randint(0,100),"resets_at":random.choice([1000,2000000000])}
    name=f"f{i:03d}"
    open(f"{out}/{name}.json","w").write(json.dumps(o,indent=2)+"\n")
    v=random.choice(variants)
    if v!="default": open(f"{out}/{name}.state","w").write(v)
    envs=[]
    if random.random()<0.6: envs.append(f"COLUMNS={random.choice([40,50,51,60,72,80,97,120,150,200])}")
    if random.random()<0.15: envs.append("NERDFLAIR_CCUSAGE=0")
    if random.random()<0.15: envs.append("NERDFLAIR_MCP_HEALTH=0")
    if random.random()<0.15: envs.append("NERDFLAIR_REPO_COST=0")
    if random.random()<0.1: envs.append("NF_TMUX=1")
    if envs: open(f"{out}/{name}.env","w").write("\n".join(envs)+"\n")
print("generated", n)
