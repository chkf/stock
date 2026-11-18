function run(input) {
    const {rows,d}=setup(input);
    if(d.marketState==="BULL"){
        d.route="MOM"; momentum(rows,d);
        d.protection=Object.keys(input.securities);
    } else if(d.marketState==="TRANSITION"){
        d.route="MV"; variance(rows,d);
    } else if(d.marketState==="BEAR"){
        const bank=rows["512800.SH"];
        d.bankStatus=!bank?"insufficient":bank.close[251]/bank.close[191]-1>0 && bank.above?"eligible":"trend_failed";
        if(d.bankStatus==="eligible"){
            d.route="BANK"; d.weights["512800.SH"]=1;
            d.protection=Object.keys(input.securities);
        } else { d.route="GB"; fourClasses(rows,d); }
    }
    return describe(d);
}
