function screen(input) {
    return Object.keys(input.securities).filter(symbol => input.securities[symbol].eligible).sort().slice(0, 1);
}

function run(input) {
    const symbol = Object.keys(input.securities)[0];
    return {
        strategy: input.strategy, date: input.date, route: "ADAPTER_TEST", marketState: input.previousState,
        selected: [symbol], weights: { [symbol]: 0.1 }, scores: {}, breadth: {}, protection: []
    };
}
