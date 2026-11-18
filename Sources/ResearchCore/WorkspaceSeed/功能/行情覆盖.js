function run(input) {
    const symbols = Object.keys(input.market || {}).sort();
    return { title: "行情覆盖", text: symbols.length + " 只证券 · " + (input.asOf || "尚未获取行情"),
        rows: symbols.map(s => ({label: input.market[s].name + " " + s, value: input.market[s].bars + " 个交易日"})) };
}
