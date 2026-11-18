import XCTest

final class HistoryDateTests:XCTestCase {
    func testBothWheelsAndSourceAfterRelaunch() throws {
        let app=XCUIApplication()
        app.launchArguments=["-AppleLanguages","(zh-Hans)","-AppleLocale","zh_CN"]
        app.launchEnvironment["TZ"]="America/Los_Angeles"
        app.launch()
        func openReplay() {
            let tab=app.tabBars.buttons["回测"]
            XCTAssertTrue(tab.waitForExistence(timeout:30))
            XCTAssertFalse(app.tabBars.buttons["账户"].exists)
            tab.tap()
        }
        func button(_ id:String) -> XCUIElement { app.buttons[id].firstMatch }
        func date(_ id:String,_ value:String) -> Bool {
            let row=button(id)
            return row.label.contains(value) || (row.value as? String)?.contains(value)==true || row.staticTexts[value].exists
        }
        func eventually(_ condition:@escaping ()->Bool) -> Bool {
            XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:NSPredicate { _,_ in condition() },object:nil)],timeout:25) == .completed
        }
        func visible(_ row:XCUIElement) {
            for _ in 0..<6 where !row.isHittable { app.swipeUp() }
            XCTAssertTrue(row.isHittable)
        }
        let library=app.tabBars.buttons["资料库"]
        XCTAssertTrue(library.waitForExistence(timeout:40)); library.tap()
        button("原始资料与报告").tap()
        button("从旧电脑导入（可选）").tap()
        let text=app.textFields["archive.pair"]
        XCTAssertTrue(text.exists); text.tap()
        text.typeText(try XCTUnwrap(ProcessInfo.processInfo.environment["STOCK_TEST_PAIR"])+"\n")
        let connect=button("archive.connect")
        visible(connect); connect.tap()
        XCTAssertTrue(app.descendants(matching:.any)["archive.files"].firstMatch.waitForExistence(timeout:120),"模拟 iPhone 应通过加密直传接收并核对公开行情")
        openReplay()
        XCTAssertTrue(eventually { date("replay.start","2026-01-19") })
        button("导入快照").tap()
        XCTAssertTrue(eventually { date("replay.start","2025-10-22") })
        let start=button("replay.start")
        visible(start); start.tap()
        let wheels=app.pickerWheels
        XCTAssertTrue(wheels.firstMatch.waitForExistence(timeout:8))
        let day=wheels.allElementsBoundByIndex.first { ($0.value as? String)?.contains("22")==true }
        let wheel=try XCTUnwrap(day)
        let original=try XCTUnwrap(wheel.value as? String)
        wheel.adjust(toPickerWheelValue:original.replacingOccurrences(of:"22",with:"25"))
        button("replay.cancel").tap()
        XCTAssertTrue(date("replay.start","2025-10-22"))
        start.tap()
        wheel.adjust(toPickerWheelValue:original.replacingOccurrences(of:"22",with:"25"))
        button("replay.confirm").tap()
        XCTAssertTrue(date("replay.start","2025-10-25"))
        XCTAssertFalse(button("计算或续跑").isEnabled)
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format:"label CONTAINS %@", "不是交易日")).firstMatch.exists)
        start.tap()
        wheel.adjust(toPickerWheelValue:original.replacingOccurrences(of:"22",with:"27"))
        button("replay.confirm").tap()
        app.terminate(); app.launch(); openReplay()
        XCTAssertTrue(eventually { date("replay.start","2025-10-27") })
        let native=button("打开独立回测")
        visible(native); native.tap()
        let end=button("replay.end")
        visible(end); end.tap()
        XCTAssertTrue(app.pickerWheels.firstMatch.exists)
        button("replay.cancel").tap()
        XCTAssertTrue(date("replay.end","2026-11-17"))
        end.tap()
        let year=try XCTUnwrap(app.pickerWheels.allElementsBoundByIndex.first { ($0.value as? String)?.contains("2026")==true })
        year.adjust(toPickerWheelValue:try XCTUnwrap(year.value as? String).replacingOccurrences(of:"2026",with:"2025"))
        button("replay.confirm").tap()
        XCTAssertTrue(date("replay.end","2025-11-17"))
        let calculate=button("计算或续跑")
        visible(calculate); XCTAssertTrue(calculate.isEnabled); calculate.tap()
        let result=app.staticTexts["replay.results"].firstMatch
        let done=XCTNSPredicateExpectation(predicate:NSPredicate { _,_ in result.exists && result.label.contains("5 套回测") },object:nil)
        XCTAssertEqual(XCTWaiter.wait(for:[done],timeout:180),.completed)
        let chart=app.buttons["净值"].firstMatch
        visible(chart)
    }
}
