.PHONY: generate lint

generate:
	xcodegen generate

lint:
	swift format lint --recursive --strict App AppCore Shared Widget WidgetCore iOSApp iOSWidget Tests
