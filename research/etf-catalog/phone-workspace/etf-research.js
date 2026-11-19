// Copy to 设计/功能/etf-research.js and register as a workspace action.
function run(input) {
    const pool = input.records && input.records["etf-universe"];
    if (!pool || pool.schema !== 1 || !Array.isArray(pool.directions)) {
        return { title: "ETF 算法研究", text: "请将 etf-universe.json 保存到研究工作区的「输入」文件夹。" };
    }

    const market = input.market || {};
    const covered = pool.directions.filter(item => market[item.etf] && market[item.etf].bars > 0);
    const query = ((input.fields || {}).etfQuery || "").trim().toLowerCase();
    const visible = pool.directions.filter(item =>
        [item.asset, item.direction, item.etf, item.etf_name, item.signal_code || "", item.signal_name]
            .some(value => value.toLowerCase().includes(query))
    );
    return {
        title: "ETF 算法研究",
        text: pool.as_of + " · " + pool.directions.length + " 个方向 · 显示 " + visible.length +
            " 个 · 当前 App 行情有日线的代表 " + covered.length + " 只",
        rows: visible.map(item => ({
            label: item.direction + " · " + item.etf,
            value: item.signal_name + " · 十日成交额中位数 " + item.median_turnover_wan + " 万元"
        }))
    };
}
