function run(input) {
    const {rows,d}=setup(input); d.route="MOM"; momentum(rows,d);
    d.protection=Object.keys(input.securities); return describe(d);
}
