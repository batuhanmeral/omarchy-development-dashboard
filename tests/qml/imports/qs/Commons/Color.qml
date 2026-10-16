pragma Singleton
import QtQuick

QtObject {
    property color background: "#202020"
    property color accent: "#80aaff"
    property color muted: "#909090"
    property color urgent: "#ff8080"
    property var popups: ({
            text: "#eeeeee"
        })
}
