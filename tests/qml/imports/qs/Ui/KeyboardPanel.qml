import QtQuick

// Test stand-in for Omarchy's qs.Ui.KeyboardPanel: builds `content` on first open and focuses it.
Item {
    id: root
    property Item anchorItem: null
    property var bar: null
    property var owner: null
    property bool open: false
    property Item focusTarget: null
    property int contentWidth: 460
    property int contentHeight: 600
    property Component content: null
    readonly property Item loadedContent: loader.item
    readonly property real loadedContentHeight: loader.item ? loader.item.implicitHeight : 0
    function fittedContentWidth(width) {
        return width;
    }
    function fittedContentHeight(height, cap) {
        return Math.min(height, cap);
    }
    width: contentWidth
    height: contentHeight
    onOpenChanged: if (open && focusTarget)
        focusTarget.forceActiveFocus()
    Loader {
        id: loader
        anchors.fill: parent
        active: root.open || !!item
        sourceComponent: root.content
        onLoaded: if (root.open)
            item.forceActiveFocus()
    }
}
