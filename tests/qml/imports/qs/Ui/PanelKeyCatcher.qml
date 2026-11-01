import QtQuick

// Test stand-in for Omarchy's qs.Ui.PanelKeyCatcher with the same key-to-signal mapping for the
// keys this plugin handles.
Item {
    property bool blocked: false
    signal moveRequested(int dx, int dy)
    signal activateRequested
    signal closeRequested
    signal tabRequested(int direction)
    signal textKey(string text, int modifiers)
    focus: true
    Keys.priority: Keys.BeforeItem
    Keys.onPressed: function (event) {
        if (blocked)
            return;
        event.accepted = true;
        if (event.key === Qt.Key_Escape)
            closeRequested();
        else if (event.key === Qt.Key_Down || event.text === "j")
            moveRequested(0, 1);
        else if (event.key === Qt.Key_Up || event.text === "k")
            moveRequested(0, -1);
        else if (event.key === Qt.Key_Right || event.text === "l")
            moveRequested(1, 0);
        else if (event.key === Qt.Key_Left || event.text === "h")
            moveRequested(-1, 0);
        else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter)
            activateRequested();
        else if (event.text && event.text.length === 1)
            textKey(event.text, event.modifiers);
        else
            event.accepted = false;
    }
}
