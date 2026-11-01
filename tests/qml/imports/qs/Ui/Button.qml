import QtQuick

// Test stand-in for Omarchy's qs.Ui.Button. Like the real one, a focusable button takes focus
// when clicked and answers Return/Space while it has it.
Item {
    id: root
    property string text: ""
    property string iconText: ""
    property string tooltipText: ""
    property bool selected: false
    property bool bordered: false
    property bool focusable: false
    property bool iconSpinning: false
    property real horizontalPadding: 10
    property color foreground: "white"
    signal clicked
    function click() {
        if (focusable)
            forceActiveFocus();
        clicked();
    }
    activeFocusOnTab: focusable
    Keys.onReturnPressed: if (focusable)
        root.clicked()
    Keys.onSpacePressed: if (focusable)
        root.clicked()
    implicitWidth: 60
    implicitHeight: 24
}
