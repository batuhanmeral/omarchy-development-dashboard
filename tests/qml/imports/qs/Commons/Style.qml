pragma Singleton
import QtQuick

// Deterministic theme fixture; qmltestrunner cannot load Quickshell's embedded plugins.
QtObject {
    property int cornerRadius: 6
    property int normalBorderWidth: 1
    property var font: ({
            family: "Sans Serif",
            caption: 10,
            bodySmall: 11,
            body: 12,
            subtitle: 13,
            title: 14
        })
    property var bar: ({
            iconSlot: 27
        })
    property var spacing: ({
            sm: 4,
            md: 6,
            lg: 8,
            xl: 10,
            xxl: 12,
            panelGap: 14,
            controlPaddingX: 10,
            inputPaddingY: 7
        })
    function space(value) {
        return value;
    }
    function selectionFillFor(foreground, accent) {
        return Qt.alpha(foreground, 0.35);
    }
    function controlFill(focused, hot, foreground, accent) {
        return Qt.alpha(foreground, focused || hot ? 0.08 : 0.04);
    }
    function controlBorder(focused, hot, foreground, accent) {
        return Qt.alpha(foreground, 0.4);
    }
}
