import QtQuick 2.15
import QtQuick.Controls 2.15
import QtQuick.Layouts 1.15

Item {
    id: root
    width: 640
    height: 860

    property int    deliveryStatus: 0
    property var    exchanges: []
    property string myId: ""
    property string currentRoom: "agora"
    property bool   identityInit: false
    property bool   identityLocked: false
    property string identityFp: ""
    property string identityBackend: ""
    property string freshMnemonic: ""   // held only while the reveal popup is open
    property var    providers: []       // verified roster from signed announces
    property bool   requireEncryption: false
    property string preferredProvider: ""   // "" = auto
    property string modelFilter: ""         // "" = any model

    // ── Logos bridge helpers ─────────────────────────────────────────

    function callInf(method, args) {
        if (typeof logos === "undefined" || !logos.callModule) {
            console.log("logos bridge unavailable")
            return null
        }
        return logos.callModule("inference", method, args)
    }

    // Basecamp JSON-encodes every remote-method return, so a C++ QString arrives
    // in QML as a JSON-string literal. Unwrap that layer before using.
    function unwrapRemote(raw, defaultVal) {
        if (raw === null || raw === undefined) return defaultVal
        if (typeof raw !== "string") return raw
        try { return JSON.parse(raw) } catch (e) { return defaultVal }
    }

    function refresh() {
        const sNum = unwrapRemote(callInf("deliveryStatus", []), 0)
        deliveryStatus = (typeof sNum === "number") ? sNum : 0
        if (myId === "") {
            const v = unwrapRemote(callInf("myId", []), "")
            myId = (typeof v === "string") ? v : ""
        }
        const r = unwrapRemote(callInf("room", []), "agora")
        if (typeof r === "string" && r.length > 0) currentRoom = r
        const inner = unwrapRemote(callInf("listExchanges", []), [])
        try {
            exchanges = (typeof inner === "string") ? JSON.parse(inner) : inner
        } catch (e) { exchanges = [] }
        refreshIdentity()
        const provRaw = unwrapRemote(callInf("listProviders", []), [])
        try {
            providers = (typeof provRaw === "string") ? JSON.parse(provRaw) : provRaw
        } catch (e) { providers = [] }
    }

    function liveProviders() {
        var n = 0
        for (var i = 0; i < providers.length; i++)
            if (providers[i].live) n++
        return n
    }

    function refreshIdentity() {
        const raw = unwrapRemote(callInf("identityStatus", []), "")
        try {
            const st = (typeof raw === "string") ? JSON.parse(raw) : raw
            identityInit      = !!st.initialized
            identityLocked    = !!st.locked
            identityFp        = st.fingerprint || ""
            identityBackend   = st.backend || ""
            requireEncryption = !!st.requireEncryption
            preferredProvider = st.preferredProvider || ""
            modelFilter       = st.modelFilter || ""
        } catch (e) { /* keep previous state */ }
    }

    function providerModels(p) {
        return (p.models && p.models.length > 0) ? p.models.join(", ") : (p.model || "?")
    }

    function providerLabel(fp) {
        for (var i = 0; i < providers.length; i++)
            if (providers[i].id === fp)
                return (providers[i].origin === "discovery" ? "🌐 " : "🚪 ")
                       + fp.substring(0, 10) + "… (" + providerModels(providers[i]) + ")"
        return fp.substring(0, 10) + "…"
    }

    // Every distinct model advertised by a live provider — feeds the model picker.
    function distinctModels() {
        var out = []
        for (var i = 0; i < providers.length; i++) {
            if (!providers[i].live) continue
            var ms = (providers[i].models && providers[i].models.length > 0)
                     ? providers[i].models : [providers[i].model]
            for (var j = 0; j < ms.length; j++)
                if (ms[j] && out.indexOf(ms[j]) === -1) out.push(ms[j])
        }
        out.sort()
        return out
    }

    function providerServes(p, m) {
        if (!m || m.length === 0) return true
        var ms = (p.models && p.models.length > 0) ? p.models : [p.model]
        return ms.indexOf(m) !== -1
    }

    function findProvider(fp) {
        for (var i = 0; i < providers.length; i++)
            if (providers[i].id === fp) return providers[i]
        return null
    }

    // Providers a prompt could go to right now (live + serving the model filter).
    function eligibleProviders() {
        var n = 0
        for (var i = 0; i < providers.length; i++)
            if (providers[i].live && providerServes(providers[i], modelFilter)) n++
        return n
    }

    // One plain sentence: where will my next prompt go?
    function routingSummary() {
        if (preferredProvider.length > 0) {
            var p = findProvider(preferredProvider)
            return "Prompts go to 📌 " + preferredProvider.substring(0, 10) + "…"
                   + (modelFilter ? " running " + modelFilter : (p ? " (" + (p.model || "?") + ")" : ""))
        }
        var n = eligibleProviders()
        if (n === 0) return modelFilter
            ? "⚠ no live provider serves " + modelFilter + " — prompts will wait/fail"
            : "⚠ no live providers yet — listening for capability cards…"
        return "Auto: best of " + n + " available provider(s)"
               + (modelFilter ? " serving " + modelFilter : "")
    }

    function unlockIdentity() {
        const ok = unwrapRemote(callInf("unlock", [unlockField.text]), false)
        if (ok === true) unlockField.text = ""
        refreshIdentity()
    }

    function createIdentity() {
        const m = unwrapRemote(callInf("createAccount", [""]), "")
        refreshIdentity()
        if (typeof m === "string" && m.length > 0) {
            freshMnemonic = m
            mnemonicPopup.open()
        }
    }

    function importIdentity() {
        const phrase = importField.text.trim()
        if (phrase.length === 0) return
        const ok = unwrapRemote(callInf("importAccount", [phrase, ""]), false)
        if (ok === true) importField.text = ""
        refreshIdentity()
    }

    function send() {
        const p = promptField.text.trim()
        if (p.length === 0 || deliveryStatus === 0) return
        callInf("sendPrompt", [p])
        promptField.text = ""
        refresh()
    }

    function statusText(s) {
        if (s === 0) return "Off"
        if (s === 1) return "Connecting…"
        if (s === 2) return "Connected"
        if (s === 3) return "Error"
        return ""
    }
    function statusColor(s) {
        if (s === 2) return "#34a853"
        if (s === 1) return "#fbbc04"
        if (s === 3) return "#ea4335"
        return "#9aa5b1"
    }
    function topicFor(room) { return "/inference/1/" + room + "/json" }

    // ── Layout ───────────────────────────────────────────────────────

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 20
        spacing: 12

        // Header
        RowLayout {
            Layout.fillWidth: true
            spacing: 10
            Text {
                text: "AI Inference"
                font.pixelSize: 24
                font.weight: Font.DemiBold
                Layout.fillWidth: true
            }
            Rectangle { width: 10; height: 10; radius: 5; color: statusColor(deliveryStatus) }
            Text { text: statusText(deliveryStatus); color: "#444"; font.pixelSize: 13 }
            Button {
                text: deliveryStatus === 0 ? "Start" : "Stop"
                onClicked: {
                    if (deliveryStatus === 0) callInf("startDelivery", [])
                    else                      callInf("stopDelivery",  [])
                    refresh()
                }
            }
        }

        Text {
            visible: myId.length > 0
            text: "my id: " + myId + "   ·   topic: " + topicFor(currentRoom)
            color: "#888"
            font.pixelSize: 11
        }

        // Identity chip (once an account exists)
        Text {
            visible: identityInit
            text: "identity: " + identityFp.substring(0, 16) + "…   ·   " + identityBackend
                  + (deliveryStatus === 2
                     ? (liveProviders() > 0
                        ? "   ·   🔒 " + liveProviders() + " provider(s) — prompts encrypted"
                        : "   ·   ⚠ no providers heard — prompts go plaintext")
                     : "")
            color: "#666"
            font.pixelSize: 11

            MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: { clipProxy.text = identityFp; clipProxy.selectAll(); clipProxy.copy() }
            }
        }
        // Invisible helper so clicking the chip copies the full fingerprint.
        TextEdit { id: clipProxy; visible: false }

        // Unlock card (passphrase-protected key file on disk)
        Rectangle {
            visible: identityLocked
            Layout.fillWidth: true
            Layout.preferredHeight: 76
            color: "#eef4ff"
            border.color: "#a9c7f0"; border.width: 1; radius: 8

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: 12
                spacing: 8
                Text {
                    text: "🔐 Identity locked"
                    font.pixelSize: 14; font.weight: Font.DemiBold; color: "#234a86"
                }
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8
                    TextField {
                        id: unlockField
                        Layout.fillWidth: true
                        echoMode: TextInput.Password
                        placeholderText: "passphrase"
                        font.pixelSize: 12
                        onAccepted: unlockIdentity()
                    }
                    Button {
                        text: "Unlock"
                        enabled: unlockField.text.length > 0
                        onClicked: unlockIdentity()
                    }
                }
            }
        }

        // Identity setup card (first run — hidden once an identity exists or is locked)
        Rectangle {
            visible: !identityInit && !identityLocked
            Layout.fillWidth: true
            Layout.preferredHeight: idCol.implicitHeight + 24
            color: "#fff8e6"
            border.color: "#f0d58c"; border.width: 1; radius: 8

            ColumnLayout {
                id: idCol
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.margins: 12
                spacing: 8

                Text {
                    text: "No identity yet"
                    font.pixelSize: 14
                    font.weight: Font.DemiBold
                    color: "#7a5c00"
                }
                Text {
                    Layout.fillWidth: true
                    wrapMode: Text.WordWrap
                    font.pixelSize: 12
                    color: "#7a5c00"
                    text: "One account backs everything — signing keys, encryption keys, "
                        + "and (soon) rate-limit membership. Create one, or import an "
                        + "existing seed phrase."
                }
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8
                    Button { text: "Create new account"; onClicked: createIdentity() }
                    TextField {
                        id: importField
                        Layout.fillWidth: true
                        placeholderText: "…or paste a seed phrase to import"
                        font.pixelSize: 12
                        onAccepted: importIdentity()
                    }
                    Button {
                        text: "Import"
                        enabled: importField.text.trim().length > 0
                        onClicked: importIdentity()
                    }
                }
            }
        }

        // Room row
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 52
            color: "#f8f9fa"
            border.color: "#dfe3e8"; border.width: 1; radius: 8
            RowLayout {
                anchors.fill: parent
                anchors.margins: 10
                spacing: 8
                Text { text: "Room"; color: "#555"; font.pixelSize: 13 }
                // No binding to currentRoom — that would clobber typing on every poll.
                TextField {
                    id: roomField
                    Layout.fillWidth: true
                    placeholderText: currentRoom
                }
                Button {
                    text: "Join"
                    enabled: roomField.text.trim().length > 0
                             && roomField.text.trim() !== currentRoom
                    onClicked: { callInf("joinRoom", [roomField.text.trim()]); refresh() }
                }
            }
        }

        // Routing controls: pick a model (from what the marketplace actually
        // offers), pick a provider (only ones serving that model), and see in
        // one sentence where the next prompt will go.
        Rectangle {
            visible: identityInit
            Layout.fillWidth: true
            Layout.preferredHeight: 78
            color: "#f8f9fa"
            border.color: "#dfe3e8"; border.width: 1; radius: 8
            ColumnLayout {
                anchors.fill: parent
                anchors.margins: 10
                spacing: 6
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8
                    Text { text: "Model"; color: "#555"; font.pixelSize: 13 }
                    ComboBox {
                        id: modelBox
                        Layout.preferredWidth: 170
                        font.pixelSize: 12
                        // Union of every model advertised by live providers —
                        // no typing, no guessing names.
                        model: {
                            var m = [{ text: "Any model", val: "" }]
                            var ds = distinctModels()
                            for (var i = 0; i < ds.length; i++)
                                m.push({ text: ds[i], val: ds[i] })
                            return m
                        }
                        textRole: "text"
                        currentIndex: {
                            for (var i = 0; i < model.length; i++)
                                if (model[i].val === modelFilter) return i
                            return 0
                        }
                        onActivated: {
                            var v = model[currentIndex].val || ""
                            callInf("setModelFilter", [v])
                            // A pinned provider that can't serve the new model
                            // would silently never be picked — unpin instead.
                            var p = findProvider(preferredProvider)
                            if (p && !providerServes(p, v))
                                callInf("setPreferredProvider", [""])
                            refreshIdentity()
                        }
                    }
                    Text { text: "Provider"; color: "#555"; font.pixelSize: 13 }
                    ComboBox {
                        id: providerBox
                        Layout.fillWidth: true
                        font.pixelSize: 12
                        // Auto + only live providers that serve the chosen model.
                        model: {
                            var m = [{ text: "Auto — pick for me", fp: "" }]
                            for (var i = 0; i < providers.length; i++)
                                if (providers[i].live
                                    && providerServes(providers[i], modelFilter))
                                    m.push({ text: providerLabel(providers[i].id),
                                             fp: providers[i].id })
                            return m
                        }
                        textRole: "text"
                        // Bind the shown selection to the backend's actual choice, so
                        // the 1s poll (which rebuilds `model`) can't reset it to Auto.
                        currentIndex: {
                            for (var i = 0; i < model.length; i++)
                                if (model[i].fp === preferredProvider) return i
                            return 0   // preferred not live → show Auto
                        }
                        onActivated: {
                            callInf("setPreferredProvider", [model[currentIndex].fp || ""])
                            refreshIdentity()
                        }
                    }
                    CheckBox {
                        text: "Require 🔒"
                        checked: requireEncryption
                        font.pixelSize: 12
                        onToggled: {
                            callInf("setRequireEncryption", [checked])
                            refreshIdentity()
                        }
                    }
                }
                Text {
                    Layout.fillWidth: true
                    text: routingSummary()
                    color: text.indexOf("⚠") === 0 ? "#b26a00" : "#188038"
                    font.pixelSize: 11
                    elide: Text.ElideRight
                }
            }
        }

        // Marketplace: every provider heard on the global discovery topic (🌐)
        // or in this room (🚪). Click a row to pin prompts to that provider;
        // click it again to go back to Auto. Rows that don't serve the chosen
        // model are dimmed and unclickable.
        Rectangle {
            visible: identityInit && providers.length > 0
            Layout.fillWidth: true
            Layout.preferredHeight: Math.min(34 + providers.length * 30, 140)
            color: "#f8f9fa"
            border.color: "#dfe3e8"; border.width: 1; radius: 8

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: 10
                spacing: 4

                RowLayout {
                    Layout.fillWidth: true
                    Text {
                        text: "Marketplace — " + liveProviders() + " live provider(s)"
                        color: "#555"; font.pixelSize: 12; font.weight: Font.DemiBold
                        Layout.fillWidth: true
                    }
                    Text {
                        text: preferredProvider.length > 0
                              ? "click 📌 row to unpin" : "click a row to pin"
                        color: "#9aa5b1"; font.pixelSize: 10
                    }
                }
                ListView {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    clip: true
                    model: providers
                    delegate: Rectangle {
                        property bool pinned: modelData.id === preferredProvider
                        property bool eligible: modelData.live
                                                && providerServes(modelData, modelFilter)
                        width: ListView.view.width
                        height: 28
                        radius: 4
                        opacity: eligible ? 1.0 : 0.4
                        color: pinned ? "#e8f0fe"
                               : (pRow.containsMouse && eligible ? "#f1f3f4" : "transparent")
                        border.color: pinned ? "#a9c7f0" : "transparent"
                        border.width: pinned ? 1 : 0

                        RowLayout {
                            anchors.fill: parent
                            anchors.leftMargin: 6; anchors.rightMargin: 6
                            spacing: 8
                            Text {
                                text: (pinned ? "📌 " : "")
                                      + (modelData.origin === "discovery" ? "🌐" : "🚪")
                                      + (modelData.live ? "" : " 💤")
                                font.pixelSize: 12
                            }
                            Text {
                                text: modelData.id.substring(0, 12) + "…"
                                font.pixelSize: 12; font.family: "Menlo"
                                color: "#1f2d3d"
                            }
                            Text {
                                Layout.fillWidth: true
                                text: providerModels(modelData)
                                      + (!modelData.live ? "  (last heard "
                                         + Math.floor(modelData.ageMs / 1000) + "s ago)"
                                         : (!eligible ? "  (no " + modelFilter + ")" : ""))
                                font.pixelSize: 12; color: "#555"
                                elide: Text.ElideRight
                            }
                            // Users only need to know if it can take a prompt NOW.
                            // Slot counts are operator telemetry — the auto-picker
                            // already weighs load internally.
                            Text {
                                visible: modelData.cap > 0 && modelData.load >= modelData.cap
                                text: "busy"
                                font.pixelSize: 11
                                color: "#c5221f"
                            }
                            Text {
                                text: modelData.price || "free"
                                font.pixelSize: 11; color: "#888"
                            }
                        }
                        MouseArea {
                            id: pRow
                            anchors.fill: parent
                            hoverEnabled: true
                            enabled: eligible
                            cursorShape: eligible ? Qt.PointingHandCursor : Qt.ArrowCursor
                            onClicked: {
                                // Toggle: pin this provider ⟷ back to Auto.
                                const fp = pinned ? "" : modelData.id
                                callInf("setPreferredProvider", [fp])
                                refreshIdentity()
                            }
                        }
                    }
                }
            }
        }

        // Prompt composer
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 110
            color: "#f8f9fa"
            border.color: "#dfe3e8"; border.width: 1; radius: 8
            ColumnLayout {
                anchors.fill: parent
                anchors.margins: 10
                spacing: 8
                ScrollView {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    clip: true
                    TextArea {
                        id: promptField
                        placeholderText: "Ask the model anything…  (Ctrl+Enter to send)"
                        wrapMode: TextArea.Wrap
                        font.pixelSize: 13
                        selectByMouse: true
                        Keys.onPressed: (e) => {
                            if ((e.modifiers & Qt.ControlModifier) &&
                                (e.key === Qt.Key_Return || e.key === Qt.Key_Enter)) {
                                send(); e.accepted = true
                            }
                        }
                    }
                }
                Button {
                    Layout.alignment: Qt.AlignRight
                    text: "Send prompt"
                    enabled: deliveryStatus !== 0 && promptField.text.trim().length > 0
                    onClicked: send()
                }
            }
        }

        RowLayout {
            Layout.fillWidth: true
            Text {
                text: exchanges.length > 0 ? exchanges.length + " prompt(s)" : ""
                color: "#666"; font.pixelSize: 12; Layout.fillWidth: true
            }
            Button {
                text: "Clear"
                visible: exchanges.length > 0
                onClicked: { callInf("clearExchanges", []); refresh() }
            }
        }

        // Exchange list (newest first)
        ListView {
            id: listView
            Layout.fillWidth: true
            Layout.fillHeight: true
            model: exchanges
            spacing: 10
            clip: true

            delegate: Rectangle {
                width: listView.width
                height: col.implicitHeight + 22
                color: "white"
                border.color: modelData.failed ? "#ea4335"
                              : modelData.answered ? "#34a853" : "#dfe3e8"
                border.width: 1
                radius: 8

                ColumnLayout {
                    id: col
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: parent.top
                    anchors.margins: 12
                    spacing: 6

                    // The prompt (what you asked)
                    Text {
                        text: "🧑  " + modelData.prompt
                        font.pixelSize: 13
                        font.weight: Font.DemiBold
                        color: "#1f2d3d"
                        wrapMode: Text.WordWrap
                        Layout.fillWidth: true
                    }

                    Rectangle { Layout.fillWidth: true; height: 1; color: "#eef1f4" }

                    // The response (thinking / answer / failed)
                    Text {
                        Layout.fillWidth: true
                        wrapMode: Text.WordWrap
                        textFormat: Text.PlainText
                        font.pixelSize: 13
                        color: modelData.failed ? "#c5221f"
                               : modelData.answered ? "#1f2d3d" : "#9a7700"
                        text: modelData.failed
                              ? "⚠  no provider answered — try again or pick another provider"
                              : modelData.answered
                                ? ("🤖  " + (modelData.text && modelData.text.length > 0
                                            ? modelData.text : "(empty response)"))
                                : ("🤖  thinking… " + Math.floor(modelData.ageMs / 1000) + "s"
                                   + (modelData.retries > 0
                                      ? "  (retry " + modelData.retries + ")" : ""))
                    }

                    // Footer: sealed · model · provider · latency
                    Text {
                        visible: modelData.answered
                        text: (modelData.sealed ? "🔒 E2E  ·  " : "")
                              + (modelData.model || "model")
                              + "  ·  " + (modelData.provider || "?")
                              + "  ·  " + modelData.rttMs + " ms"
                        color: "#188038"
                        font.pixelSize: 11
                    }
                }
            }

            Label {
                anchors.centerIn: parent
                visible: exchanges.length === 0
                width: parent.width - 40
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.WordWrap
                text: deliveryStatus === 0
                      ? "Press Start, type a prompt, and Send.\nA logoscore-CLI provider running ollama will answer."
                      : "Type a prompt and Send — it goes onto\n" + topicFor(currentRoom)
                color: "#9aa5b1"
            }
        }
    }

    // Seed-phrase reveal — the mnemonic exists only here, once. Closing it is
    // the user's confirmation that it's written down.
    Popup {
        id: mnemonicPopup
        anchors.centerIn: parent
        width: Math.min(parent.width - 60, 520)
        modal: true
        closePolicy: Popup.NoAutoClose
        onClosed: freshMnemonic = ""

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: 8
            spacing: 10

            Text {
                text: "Your seed phrase — write it down now"
                font.pixelSize: 15
                font.weight: Font.DemiBold
            }
            Text {
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                font.pixelSize: 12
                color: "#a33"
                text: "This is the ONLY backup of your identity and it will not be "
                    + "shown again. Anyone who has it can become you."
            }
            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: mnemonicText.implicitHeight + 20
                color: "#f4f6f8"; radius: 6
                border.color: "#dfe3e8"; border.width: 1
                TextEdit {
                    id: mnemonicText
                    anchors.fill: parent
                    anchors.margins: 10
                    text: freshMnemonic
                    readOnly: true
                    selectByMouse: true
                    wrapMode: TextEdit.Wrap
                    font.pixelSize: 14
                    font.family: "Menlo"
                }
            }
            Button {
                Layout.alignment: Qt.AlignRight
                text: "I've written it down"
                onClicked: mnemonicPopup.close()
            }
        }
    }

    // Poll for live updates. A production app would subscribe to inference's
    // responseReceived / promptSent events via logos.onModuleEvent(...).
    Timer {
        interval: 1000
        running: true
        repeat: true
        onTriggered: refresh()
    }

    Component.onCompleted: refresh()
}
