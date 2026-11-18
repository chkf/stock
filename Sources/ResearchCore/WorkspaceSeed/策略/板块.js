function run(input) {
    const {rows,d}=setup(input), strong=[], eligible=new Set();
    d.route="GROUP"; d.sectorStates={};
    for(const [group,ss] of Object.entries(sectorMap)){
        const state=classify(ss.filter(s=>rows[s]).map(s=>rows[s]),input.previousSectors[group]).state;
        d.sectorStates[group]=state;
        if(state==="BULL")strong.push(...ss);
        if(state==="BULL" || state==="TRANSITION")ss.forEach(s=>eligible.add(s));
    }
    momentum(rows,d,strong);
    const idle=1-d.selected.length/3;
    if(idle>1e-12)fourClasses(rows,d,idle,Object.keys(rows).filter(s=>eligible.has(s) || ["bond","commodity"].includes(rows[s].group)));
    d.protection=Object.keys(input.securities).filter(s=>input.securities[s].group.startsWith("domestic") || input.securities[s].group==="overseas_equity");
    return describe(d);
}
