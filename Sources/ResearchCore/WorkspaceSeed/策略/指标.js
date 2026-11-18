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
// NumPy float64 pairwise reduction for contiguous vectors shorter than 128.
function arraySum(a) {
    if(a.length<8) return a.reduce((s,x)=>s+x,-0);
    const acc=a.slice(0,8);
    let j=8;
    for(;j+7<a.length;j+=8) for(let i=0;i<8;i++) acc[i]+=a[j+i];
    let sum=((acc[0]+acc[1])+(acc[2]+acc[3]))+((acc[4]+acc[5])+(acc[6]+acc[7]));
    for(;j<a.length;j++) sum+=a[j];
    return sum;
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
function describe(d) {
    d.resetHighOnEntry=["MOM","BANK"].includes(d.route);
    const titles={BANK:"配置银行 ETF",MOM:"配置动量领先的 ETF",MV:"采用最小波动配置",GB:"按四类资产配置",GROUP:"按板块强弱配置",CASH:"保留现金，等待信号"};
    const notes={
        BANK:"A 股偏弱。银行 ETF 近 60 个交易日收益为正，且收盘高于 200 日均线。",
        MOM:"半年收益为正的 ETF 中，按一年收益取前三，各占三分之一，空位留现金。",
        MV:"用 126 个交易日的收益估算协方差，单只目标上限 35%。",
        GB:"A 股、海外股票、商品、国债各占四分之一，缺类留现金。",
        GROUP:"分板块和海外区域判断强弱，强势组按动量选取，剩余资金按规则分配。",
        CASH:"可用历史不足以判断市场状态。"
    };
    d.headline=Object.keys(d.weights).length ? titles[d.route] : "保留现金";
    d.rationale=(d.bankStatus==="trend_failed"?"银行趋势条件未通过。":d.bankStatus==="insufficient"?"银行 ETF 历史不足。":"")+
        (d.route==="MV" && !Object.keys(d.weights).length?"协方差计算至少需要三只合格 ETF。":notes[d.route]);
    return d;
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
        const w=rows[s].close, r=w.slice(-126).map((v,i)=>v/w[125+i]-1), avg=arraySum(r)/r.length;
        return r.map(v=>v-avg);
    });
    const matrix=Array(n*n).fill(0), product=gramMatrix(n,126,centered.flat());
    const diagonal=[];
    for(let i=0;i<n;i++){
        for(let j=0;j<=i;j++){
            const covariance=product[i*n+j]*(1/125), c=i===j?covariance+1e-10:0.5*covariance;
            matrix[i*n+j]=matrix[j*n+i]=c;
        }
        diagonal.push(matrix[i*n+i]);
    }
    const scale=arraySum(diagonal)/n;
    const w=minimumVariance(n,matrix.map(x=>x/scale)).map(x=>Math.max(0,x));
    const denom=Math.max(1,arraySum(w));
    symbols.forEach((s,i)=>{if(w[i]/denom>1e-10)d.weights[s]=w[i]/denom;});
}
