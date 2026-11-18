"use strict";
const sectorMap = {
    BANK:["512800.SH"], NONBANK:["512070.SH"], STAPLES:["159928.SZ"], DISCRETIONARY:["159936.SZ"],
    HEALTH:["512010.SH"], IT:["159939.SZ"], SEMI:["512480.SH"], TELECOM:["515880.SH"],
    DEFENCE:["512660.SH"], SOLAR:["515790.SH"], ENERGY:["159945.SZ"], MATERIALS:["159944.SZ"],
    POWER:["159611.SZ"], PROPERTY:["512200.SH"], US:["513100.SH","513500.SH"], HK:["159920.SZ"], EU:["513030.SH"]
};
const assetClasses = ["domestic_equity","overseas_equity","commodity","bond"];
function mean(a) {
    let sum=0, correction=0;
    for (const x of a) { const y=x-correction, next=sum+y; correction=(next-sum)-y; sum=next; }
    return sum/a.length;
}
function panel(input) {
    const rows={};
    for (const s of Object.keys(input.securities).sort()) {
        const sec=input.securities[s], w=sec.close.slice(-252);
        if (w.length !== 252 || w.some(x=>x===null)) continue;
        if (w.some(x=>!Number.isFinite(x) || x<=0)) throw Error(s+" 信号价无效");
        const p=w[251], prev=sec.close.at(-253);
        const ma60=mean(w.slice(-60)), ma200=mean(w.slice(-200));
        const slope60=ma60/mean(w.slice(-80,-20))-1, slope200=ma200/mean(w.slice(-220,-20))-1;
        rows[s]={group:sec.group.startsWith("domestic")?"domestic_equity":sec.group, close:w,
            up60:p>ma60 && slope60>0, down60:p<ma60 && slope60<0,
            up200:p>ma200 && slope200>0, down200:p<ma200 && slope200<0, above:p>ma200,
            momentum:p>w[125] && prev>0 ? p/prev-1 : null};
    }
    return rows;
}
function classify(rows, previous="UNKNOWN") {
    const n=rows.length, threshold=0.6, breadth={count:n,threshold};
    if (!n) return {state:previous,breadth};
    for (const key of ["up60","down60","up200","down200"]) breadth[key]=rows.filter(r=>r[key]).length/n;
    const state=breadth.down60>=threshold || breadth.down200>=threshold ? "BEAR" :
        breadth.up60>=threshold && breadth.up200>=threshold ? "BULL" : "TRANSITION";
    return {state,breadth};
}
function setup(input) {
    const rows=panel(input), cls=classify(Object.values(rows).filter(r=>r.group==="domestic_equity"),input.previousState);
    return {rows, d:{strategy:input.strategy,date:input.date,route:"CASH",marketState:cls.state,breadth:cls.breadth,
        selected:[],scores:{},weights:{},protection:[],exitDrawdown:0.2}};
}
function momentum(rows,d,allowed=Object.keys(rows)) {
    d.scores={};
    for (const s of allowed) if(rows[s] && rows[s].momentum!==null) d.scores[s]=rows[s].momentum;
    d.selected=Object.keys(d.scores).sort((a,b)=>d.scores[b]-d.scores[a] || (a<b?-1:1)).slice(0,3);
    for (const s of d.selected) d.weights[s]=1/3;
}
function fourClasses(rows,d,fraction=1,allowed=Object.keys(rows)) {
    for (const group of assetClasses) {
        const members=allowed.filter(s=>rows[s] && rows[s].group===group && !(s in d.weights));
        for (const s of members) d.weights[s]=fraction*0.25/members.length;
    }
}
function variance(rows,d) {
    const symbols=Object.keys(rows).sort(), n=symbols.length;
    if(n<3) return;
    const centered=symbols.map(s=>{
        const w=rows[s].close, r=w.slice(-126).map((v,i)=>v/w[125+i]-1), avg=mean(r);
        return r.map(v=>v-avg);
    });
    const matrix=Array(n*n).fill(0);
    let trace=0;
    for(let i=0;i<n;i++){
        for(let j=0;j<=i;j++){
            let sum=0; for(let k=0;k<126;k++) sum+=centered[i][k]*centered[j][k];
            const c=i===j?sum/125+1e-10:0.5*sum/125;
            matrix[i*n+j]=matrix[j*n+i]=c;
        }
        trace+=matrix[i*n+i];
    }
    const w=minimumVariance(n,matrix.map(x=>x/(trace/n))).map(x=>Math.max(0,x));
    const denom=Math.max(1,w.reduce((a,b)=>a+b,0));
    symbols.forEach((s,i)=>{if(w[i]/denom>1e-10)d.weights[s]=w[i]/denom;});
}
