import QtQml

// Log text for one container at a time. Every request gets a token; a reply is shown only while
// its token is still the newest, so closing the view or picking another container drops it.
QtObject {
    property string text: ""
    property string containerId: ""
    property bool truncated: false
    property bool loading: false
    property bool failed: false
    property int generation: 0

    function begin(id, retain) {
        generation++;
        if (!retain || containerId !== id || failed) {
            text = "";
            truncated = false;
            failed = false;
        }
        containerId = id;
        loading = true;
        return generation;
    }

    function clear() {
        generation++;
        text = "";
        containerId = "";
        truncated = false;
        loading = false;
        failed = false;
    }

    function accept(token, result) {
        if (token !== generation || !containerId)
            return false;
        loading = false;
        failed = !result.ok;
        truncated = result.ok && result.data.truncated === true;
        text = result.ok ? result.data.text : result.errors.join("\n");
        return true;
    }

    function fail(token, message) {
        if (token !== generation || !containerId)
            return false;
        loading = false;
        failed = true;
        truncated = false;
        text = message;
        return true;
    }
}
