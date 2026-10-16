pragma Singleton
import QtQuick

// Deterministic theme fixture; qmltestrunner cannot load Quickshell's embedded plugins.
QtObject {
    property int cornerRadius: 6
    property var font: ({
            family: "Sans Serif",
            body: 12,
            subtitle: 14
        })
    function space(value) {
        return value;
    }
}
