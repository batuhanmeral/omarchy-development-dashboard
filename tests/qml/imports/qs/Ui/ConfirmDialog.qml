import QtQuick

Item {
    id: root
    property bool opened: false
    property string message: ""
    property string cancelText: "Cancel"
    property string confirmText: "Confirm"
    property int selectedIndex: 1
    property color foreground: "white"
    signal canceled
    signal confirmed
    visible: opened
    function handleKey(event) {
        if (!opened)
            return false;
        if (event.key === Qt.Key_Escape)
            canceled();
        else if ([Qt.Key_Left, Qt.Key_Right, Qt.Key_Tab, Qt.Key_Backtab].indexOf(event.key) >= 0)
            selectedIndex = selectedIndex === 0 ? 1 : 0;
        else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            if (selectedIndex === 0)
                canceled();
            else
                confirmed();
        } else
            return false;
        return true;
    }
    Text {
        objectName: "confirmMessage"
        text: root.message
        textFormat: Text.PlainText
    }
    Row {
        Button {
            objectName: "cancelConfirm"
            text: root.cancelText
            onClicked: root.canceled()
        }
        Button {
            objectName: "acceptConfirm"
            text: root.confirmText
            onClicked: root.confirmed()
        }
    }
}
