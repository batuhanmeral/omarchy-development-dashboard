pragma Singleton
import QtQuick

QtObject {
    function alpha(c, opacity) {
        return Qt.alpha(c, opacity);
    }
}
