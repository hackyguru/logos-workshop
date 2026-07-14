// Logos Wallet — Bedrock (base chain) + LEZ (private execution zone) in one
// tab bar. QML frontend for the logos_wallet core, which owns the node
// daemon and drives the version-matched logos_execution_zone module for all
// LEZ writes. All calls go through callModuleAsync; slow ops return
// {accepted:true} and finish via <name>Finished events (see the core).

import QtQuick 2.15
import QtQuick.Controls 2.15
import QtQuick.Layouts 1.15

Item {
    id: root
    width: 720
    height: 940

    property int tab: 0                       // 0 = Bedrock, 1 = LEZ

    // ── Bedrock state ────────────────────────────────────────────────
    property int    nodeStatus: 0             // 0 off, 1 setting up, 3 running
    property string nodeStage: ""
    property string chainMode: ""
    property double chainHeight: 0
    property double chainSlot: 0
    property int    nPeers: -1
    property int    nConnections: -1
    property string peerId: ""
    property var    baseAccounts: []
    property string lastSendTx: ""
    property bool   sendBusy: false
    property string lastInscribe: ""
    property bool   inscribeBusy: false

    // ── LEZ state ────────────────────────────────────────────────────
    property bool   lezReady: false
    property bool   lezHasWallet: false
    property bool   lezBusy: false
    property string lezStage: ""
    property string lezAccountB58: ""
    property string lezAccountHex: ""
    property string lezPublicAccountB58: ""
    property string lezPrivateBalance: ""
    property string lezPublicBalance: ""
    property string lezVault: ""
    property double lezLastSynced: -1
    property double lezHeight: -1
    property string lezMnemonic: ""
    property string lezMsg: ""
    property var    lezAccountsList: []
    property bool   lezCreateBusy: false
    property bool   lezStatusKnown: false     // first lezStatus reply has landed
    property bool   lezAutoOpened: false       // auto-open attempted this session
    property string _lezAccountsJson: ""       // change-guard for the accounts list

    property string lastError: ""
    property string copied: ""
    property int    tick: 0

    // ── Bridge helpers ───────────────────────────────────────────────
    function call(method, args, cb) {
        if (typeof logos === "undefined" || !logos.callModuleAsync) {
            lastError = "Logos bridge unavailable."; return
        }
        logos.callModuleAsync("logos_wallet", method, args, function(raw) { cb(parse(raw)) })
    }
    function parse(raw) {
        var v = raw
        for (var i = 0; i < 2 && typeof v === "string"; i++) { try { v = JSON.parse(v) } catch (e) { break } }
        if (v === null || typeof v !== "object") return { ok: false, error: "no reply" }
        // Treat only a NON-EMPTY error as a failure. Status replies (lezStatus)
        // legitimately carry an empty "error":"" alongside their fields and no
        // "ok" — those must pass through, not be swallowed as errors.
        if (v.error !== undefined && String(v.error) !== "" && v.ok === undefined) return { ok: false, error: String(v.error) }
        return v
    }
    function fail(m) { lastError = m }

    // Base58 (Bitcoin alphabet) decode → hex. Account ids are shown/copied as
    // base58, but the core expects 64-hex, so normalize before sending.
    readonly property string b58Alpha: "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
    function b58decode(str) {
        if (!str || str.length === 0) return ""
        var zeros = 0
        while (zeros < str.length && str[zeros] === "1") zeros++
        var digits = []
        for (var i = 0; i < str.length; i++) {
            var idx = b58Alpha.indexOf(str[i]); if (idx < 0) return ""
            var carry = idx
            for (var j = 0; j < digits.length; j++) { carry += digits[j] * 58; digits[j] = carry % 256; carry = Math.floor(carry / 256) }
            while (carry > 0) { digits.push(carry % 256); carry = Math.floor(carry / 256) }
        }
        var hex = ""
        for (var k = 0; k < zeros; k++) hex += "00"
        for (var m2 = digits.length - 1; m2 >= 0; m2--) hex += (digits[m2] < 16 ? "0" : "") + digits[m2].toString(16)
        return hex
    }
    // Accept a base58 OR hex account id → 64-hex, or "" if not valid.
    function acctHex(input) {
        var s = (input || "").trim()
        if (/^[0-9a-fA-F]{64}$/.test(s)) return s.toLowerCase()
        var h = b58decode(s)
        return /^[0-9a-fA-F]{64}$/.test(h) ? h.toLowerCase() : ""
    }

    // ── Bedrock actions ──────────────────────────────────────────────
    function startNode() { lastError = ""; nodeStatus = 1; call("startNode", [], function(r) { if (!r.ok) { nodeStatus = 0; fail(r.error) } }) }
    function stopNode()  { call("stopNode", [], function(r) { nodeStatus = 0; chainMode = ""; nPeers = -1 }) }
    function baseSend(to, amt) {
        lastError = ""; sendBusy = true
        call("baseSend", [to, amt], function(r) {
            sendBusy = false
            if (!r.ok) { fail(r.error); return }
            lastSendTx = String(r.tx || ""); sendToField.text = ""; sendAmtField.text = ""; refreshBase()
        })
    }
    function inscribe(t) { lastError = ""; inscribeBusy = true; call("inscribe", [t], function(r) { if (!r.ok) { inscribeBusy = false; fail(r.error) } }) }

    // ── LEZ actions ──────────────────────────────────────────────────
    function lezOpen() { lastError = ""; lezBusy = true; call("lezOpen", [], function(r) { if (!r.ok) { lezBusy = false; fail(r.error) } }) }
    function lezFund() { lastError = ""; lezMsg = ""; lezBusy = true; call("lezFund", [], function(r) { if (!r.ok) { lezBusy = false; fail(r.error) } }) }
    function lezTransfer(kind, from, to, amt) { lastError = ""; lezMsg = ""; lezBusy = true; call("lezTransfer", [kind, from, to, amt], function(r) { if (!r.ok) { lezBusy = false; fail(r.error) } }) }

    // Which transfer method moves funds from a source account to a destination
    // of the given visibility. Source type comes from the picked account; the
    // user names the recipient's type. This hides the shield/deshield jargon.
    function xferKind(srcPublic, destPublic) {
        if (srcPublic && destPublic)   return "public"       // public → public
        if (srcPublic && !destPublic)  return "shielded"     // public → private (shield)
        if (!srcPublic && !destPublic) return "private"      // private → private
        return "deshielded"                                  // private → public (deshield)
    }
    function fromLabel(a) {
        if (!a) return "Select account…"
        return (a.isPublic ? "🌐 " : "🔒 ") + shortHex(a.idB58) + " · " + fmt(a.balance)
    }
    // A private recipient is named by a receiving address (lezpriv1…), which
    // encodes their shielded keys. A public recipient is a plain account id.
    function validRecipient(text, destPublic) {
        var s = (text || "").trim()
        if (!destPublic && s.indexOf("lezpriv1") === 0) return true
        return acctHex(s).length === 64
    }
    function recipientArg(text, destPublic) {
        var s = (text || "").trim()
        if (!destPublic && s.indexOf("lezpriv1") === 0) return s
        return acctHex(s)
    }
    // Fetch a private account's receiving address and copy it to the clipboard.
    function lezCopyReceive(accountHex) {
        lastError = ""
        call("lezReceiveAddress", [accountHex], function(r) {
            if (r.ok && r.address) { copy(r.address, "recv"); lezMsg = "Receiving address copied — share it to be paid privately." }
            else fail(r.error || "Could not get the receiving address.")
        })
    }
    function lezBridgeIn(amt)  { lastError = ""; lezMsg = ""; lezBusy = true; call("lezBridgeIn", [amt], function(r) { if (!r.ok) { lezBusy = false; fail(r.error) } }) }
    function lezClaimVault(amt){ lastError = ""; lezMsg = ""; lezBusy = true; call("lezClaimVault", [amt], function(r) { if (!r.ok) { lezBusy = false; fail(r.error) } }) }

    // ── Polling ──────────────────────────────────────────────────────
    function refreshBase() {
        call("nodeStatus", [], function(r) {
            if (!r.ok && r.running === undefined) return
            if (r.running) {
                if (nodeStatus !== 1) nodeStatus = 3
                chainMode = String(r.mode || ""); chainHeight = Number(r.height || 0); chainSlot = Number(r.slot || 0)
                peerId = String(r.peerId || ""); nPeers = Number(r.nPeers); nConnections = Number(r.nConnections)
            } else if (nodeStatus === 3) { nodeStatus = 0; chainMode = "" }
            else if (nodeStatus === 1 && !r.setupBusy && !r.running && r.setupError) { nodeStatus = 0; fail(String(r.setupError)) }
        })
        if (nodeStatus === 3) call("baseAccounts", [], function(r) { if (r.ok && Array.isArray(r.accounts)) baseAccounts = r.accounts })
    }
    function refreshLez() {
        if (lezBusy) return
        call("lezStatus", [], function(r) {
            if (r.error !== undefined && r.ok === false) return
            lezReady = !!r.ready; lezHasWallet = !!r.hasWallet
            lezStatusKnown = true
            // A persistent wallet already exists → open it silently, no screen.
            if (lezHasWallet && !lezReady && !lezBusy && !lezAutoOpened) { lezAutoOpened = true; lezOpen() }
            lezAccountB58 = String(r.accountB58 || "")
            lezAccountHex = String(r.account || "")
            lezPublicAccountB58 = String(r.publicAccountB58 || "")
            lezPrivateBalance = String(r.privateBalance || ""); lezPublicBalance = String(r.publicBalance || "")
            lezVault = String(r.vault || "")
            lezLastSynced = Number(r.lastSynced !== undefined ? r.lastSynced : -1)
            lezHeight = Number(r.height !== undefined ? r.height : -1)
        })
        call("lezAccounts", [], function(r) {
            if (r.ok && Array.isArray(r.accounts)) {
                // Only reassign when the set actually changed, so polling doesn't
                // reset the From picker / other bindings while the user is typing.
                var s = JSON.stringify(r.accounts)
                if (s !== root._lezAccountsJson) { root._lezAccountsJson = s; lezAccountsList = r.accounts }
            }
        })
    }

    function lezCreateAccount(kind) { lastError = ""; lezMsg = ""; lezCreateBusy = true; call("lezCreateAccount", [kind], function(r) { if (!r.ok) { lezCreateBusy = false; fail(r.error) } }) }

    Timer {
        interval: 2500; running: true; repeat: true
        onTriggered: { tick++; if (root.tab === 0) refreshBase(); else refreshLez(); if (tick % 3 === 0) { refreshBase(); refreshLez() } }
    }
    Connections {
        target: (typeof logos !== "undefined") ? logos : null
        function onModuleEventReceived(m, e, d) {
            if (m !== "logos_wallet") return
            var r; try { r = JSON.parse(d[0]) } catch (x) { r = null }
            if (e === "nodeSetupFinished") { if (r && r.ok) { nodeStatus = 3; refreshBase() } else { nodeStatus = 0; fail(r ? r.error : "Node setup failed.") } }
            else if (e === "inscribeFinished") { inscribeBusy = false; if (r && r.ok) { lastInscribe = "confirmed ✓ " + (r.tip ? shortHex(String(r.tip)) : ""); inscribeField.text = "" } else fail(r ? r.error : "Inscription failed.") }
            else if (e === "lezOpenFinished") { lezBusy = false; if (r && r.ok) { lezReady = true; lezAccountB58 = String(r.accountB58 || ""); if (r.mnemonic && r.mnemonic.length) lezMnemonic = String(r.mnemonic); refreshLez() } else fail(r ? r.error : "Open failed.") }
            else if (e === "lezFundFinished") { lezBusy = false; if (r && r.ok) { lezMsg = r.shielded ? ("Funded " + (r.prize || 150) + " into your private balance ✓") : ("Claimed " + (r.prize || 150) + " to public; shielding to private will retry — " + (r.note || "")); refreshLez() } else fail(r ? r.error : "Funding failed.") }
            else if (e === "lezTransferFinished") { lezBusy = false; if (r && r.ok) { lezMsg = "Transfer sent ✓"; refreshLez() } else fail(r ? r.error : "Transfer failed.") }
            else if (e === "lezAccountCreated") { lezCreateBusy = false; var rr; try { rr = JSON.parse(d[0]) } catch(x){ rr=null }; if (rr && rr.ok) { lezMsg = (rr.isPublic ? "Public" : "Private") + " account created ✓"; refreshLez() } else fail(rr ? rr.error : "Create failed.") }
            else if (e === "lezBridgeFinished") { lezBusy = false; if (r && r.ok) { lezMsg = (r.kind === "deposit") ? ("Bridged in (tx " + shortHex(String(r.tx||"")) + ") — credits your vault after ~1h finality.") : "Claimed to private balance ✓"; refreshLez() } else fail(r ? r.error : "Bridge failed.") }
        }
    }
    Component.onCompleted: {
        if (typeof logos !== "undefined" && logos.onModuleEvent) {
            var evs = ["nodeSetupFinished", "inscribeFinished", "lezOpenFinished", "lezAccountCreated", "lezFundFinished", "lezTransferFinished", "lezBridgeFinished"]
            for (var i = 0; i < evs.length; i++) logos.onModuleEvent("logos_wallet", evs[i])
        }
        refreshBase(); refreshLez()
    }

    // ── Display helpers ──────────────────────────────────────────────
    function shortHex(h) { return h.length > 20 ? h.substring(0,10) + "…" + h.substring(h.length-8) : h }
    function fmt(n) { return (Number(n) < 0) ? "…" : Number(n).toLocaleString(Qt.locale(), 'f', 0) }
    TextEdit { id: clip; visible: false }
    function copy(t, label) { clip.text = t; clip.selectAll(); clip.copy(); copied = label; copyTimer.restart() }
    Timer { id: copyTimer; interval: 1500; onTriggered: root.copied = "" }

    // ── Reusable card ────────────────────────────────────────────────
    component Card: Rectangle {
        default property alias content: col.data
        property string title: ""
        Layout.fillWidth: true
        color: "#f8f9fa"; border.color: "#dfe3e8"; border.width: 1; radius: 8
        implicitHeight: col.implicitHeight + 24
        ColumnLayout {
            id: col
            anchors { left: parent.left; right: parent.right; top: parent.top; margins: 12 }
            spacing: 8
            Text { text: title; color: "#9aa5b1"; font.pixelSize: 11; font.weight: Font.DemiBold; visible: title.length > 0 }
        }
    }

    // ── Layout ───────────────────────────────────────────────────────
    ColumnLayout {
        anchors.fill: parent; anchors.margins: 16; spacing: 12

        // Header + tabs
        RowLayout {
            Layout.fillWidth: true; spacing: 10
            Text { text: "Logos Wallet"; font.pixelSize: 20; font.weight: Font.DemiBold; color: "#333" }
            Item { Layout.fillWidth: true }
            TabButtonRow {}
        }

        Rectangle {
            Layout.fillWidth: true; visible: root.lastError.length > 0
            color: "#fdecea"; border.color: "#f5b7b1"; border.width: 1; radius: 8
            implicitHeight: et.implicitHeight + 18
            Text { id: et; anchors.fill: parent; anchors.margins: 9; text: root.lastError; wrapMode: Text.Wrap; color: "#8a1f11"; font.pixelSize: 13 }
        }

        // Scrollable body
        Flickable {
            Layout.fillWidth: true; Layout.fillHeight: true
            contentWidth: width; contentHeight: body.height; clip: true
            ColumnLayout {
                id: body; width: parent.width; spacing: 12
                Loader { Layout.fillWidth: true; sourceComponent: root.tab === 0 ? bedrockTab : lezTab }
            }
        }
    }

    // ── Tab buttons ──────────────────────────────────────────────────
    component TabButtonRow: RowLayout {
        spacing: 6
        Repeater {
            model: [{ n: "Base chain", i: 0 }, { n: "Private (LEZ)", i: 1 }]
            delegate: Button {
                text: modelData.n
                checkable: true; checked: root.tab === modelData.i
                onClicked: root.tab = modelData.i
                palette.button: root.tab === modelData.i ? "#e8f0fe" : "#f0f0f0"
            }
        }
    }

    // ── BEDROCK TAB ──────────────────────────────────────────────────
    Component {
        id: bedrockTab
        ColumnLayout {
            width: parent ? parent.width : root.width
            spacing: 12

            Card {
                title: ""
                RowLayout {
                    Layout.fillWidth: true; spacing: 10
                    Rectangle { width: 12; height: 12; radius: 6
                        color: root.nodeStatus === 3 ? (root.chainMode === "Online" ? "#188038" : "#b26a00") : (root.nodeStatus === 1 ? "#b26a00" : "#9aa5b1") }
                    Text {
                        text: root.nodeStatus === 1 ? (root.nodeStage.length ? root.nodeStage + "…" : "Starting…")
                            : root.nodeStatus === 3 ? (root.chainMode === "Online" ? "Online" : (root.chainMode.length ? "Syncing…" : "Running"))
                            : "Node off"
                        color: "#333"; font.pixelSize: 15; font.weight: Font.DemiBold
                    }
                    Item { Layout.fillWidth: true }
                    Button { visible: root.nodeStatus === 3; text: "Stop"; onClicked: root.stopNode() }
                    Button { visible: root.nodeStatus === 0; text: "▶ Start node"; enabled: root.nodeStatus === 0; onClicked: root.startNode() }
                    BusyIndicator { visible: root.nodeStatus === 1; running: visible; implicitWidth: 22; implicitHeight: 22 }
                }
                GridLayout {
                    visible: root.nodeStatus === 3; Layout.fillWidth: true; columns: 2; columnSpacing: 24; rowSpacing: 5
                    Text { text: "Height"; color: "#555"; font.pixelSize: 13 }
                    Text { text: root.fmt(root.chainHeight) + "  (slot " + root.fmt(root.chainSlot) + ")"; color: "#333"; font.pixelSize: 13 }
                    Text { text: "Peers"; color: "#555"; font.pixelSize: 13 }
                    Text { text: root.nPeers >= 0 ? (root.nPeers + " · " + root.nConnections + " conns") : "—"; color: "#333"; font.pixelSize: 13 }
                }
                Text { visible: root.nodeStatus === 3 && root.chainMode !== "Online"
                    text: "This 0.2.0 node reports “Bootstrapping” as its steady state even when caught up — that's normal."
                    Layout.fillWidth: true; wrapMode: Text.Wrap; color: "#9aa5b1"; font.pixelSize: 11 }
            }

            Card {
                visible: root.nodeStatus === 3; title: "BASE WALLET"
                Repeater {
                    model: root.baseAccounts
                    delegate: RowLayout {
                        Layout.fillWidth: true; spacing: 6
                        Text { text: (modelData.role === "LeaderFunding" ? "★ " : "") + root.shortHex(modelData.address); color: "#333"; font.pixelSize: 12; font.family: "Menlo" }
                        Text { text: modelData.role; color: "#9aa5b1"; font.pixelSize: 11 }
                        ToolButton { text: root.copied === modelData.address ? "✓" : "⧉"; font.pixelSize: 12; onClicked: root.copy(modelData.address, modelData.address) }
                        Item { Layout.fillWidth: true }
                        Text { text: root.fmt(modelData.balance); color: Number(modelData.balance) > 0 ? "#188038" : "#555"; font.pixelSize: 13; font.weight: Font.DemiBold }
                    }
                }
                Text { text: "Get test tokens: copy your ★ address → faucet."; color: "#7a5c00"; font.pixelSize: 12 }
                Button { text: "Open faucet ↗"; onClicked: Qt.openUrlExternally("https://testnet.blockchain.logos.co/web/faucet/") }
            }

            Card {
                visible: root.nodeStatus === 3; title: "SEND"
                RowLayout {
                    Layout.fillWidth: true; spacing: 8
                    TextField { id: sendToField; Layout.fillWidth: true; placeholderText: "Recipient (64 hex)…"; enabled: !root.sendBusy; font.family: "Menlo"; font.pixelSize: 12 }
                    TextField { id: sendAmtField; Layout.preferredWidth: 100; placeholderText: "Amount"; enabled: !root.sendBusy; validator: RegularExpressionValidator { regularExpression: /[0-9]+/ } }
                    Button { text: root.sendBusy ? "Sending…" : "Send"; enabled: !root.sendBusy && /^[0-9a-fA-F]{64}$/.test(sendToField.text.trim()) && Number(sendAmtField.text) > 0; onClicked: root.baseSend(sendToField.text.trim(), sendAmtField.text.trim()) }
                }
                Text { visible: root.lastSendTx.length > 0; text: "✓ Sent · " + root.shortHex(root.lastSendTx); color: "#188038"; font.pixelSize: 12 }
            }

            Card {
                visible: root.nodeStatus === 3; title: "INSCRIBE"
                Text { text: "Write a short message permanently onto the base chain."; Layout.fillWidth: true; wrapMode: Text.Wrap; color: "#555"; font.pixelSize: 13 }
                RowLayout {
                    Layout.fillWidth: true; spacing: 8
                    TextField { id: inscribeField; Layout.fillWidth: true; placeholderText: "Your message…"; enabled: !root.inscribeBusy }
                    Button { text: root.inscribeBusy ? "Inscribing…" : "Inscribe"; enabled: !root.inscribeBusy && inscribeField.text.trim().length > 0; onClicked: root.inscribe(inscribeField.text.trim()) }
                }
                Text { visible: root.lastInscribe.length > 0; text: "✓ " + root.lastInscribe; color: "#188038"; font.pixelSize: 12 }
            }
        }
    }

    // ── LEZ TAB ──────────────────────────────────────────────────────
    Component {
        id: lezTab
        ColumnLayout {
            width: parent ? parent.width : root.width
            spacing: 12

            // Existing wallet opens itself — show a quiet indicator, no button.
            Card {
                visible: !root.lezReady && root.lezHasWallet; title: "PRIVATE WALLET (LEZ)"
                RowLayout {
                    Layout.fillWidth: true; spacing: 10
                    BusyIndicator { running: true; implicitWidth: 20; implicitHeight: 20 }
                    Text { text: "Opening your private wallet…"; color: "#555"; font.pixelSize: 14 }
                }
            }

            // First run only — no wallet on disk yet, so offer to create one.
            Card {
                visible: !root.lezReady && root.lezStatusKnown && !root.lezHasWallet; title: "PRIVATE WALLET (LEZ)"
                Text { Layout.fillWidth: true; wrapMode: Text.Wrap; color: "#555"; font.pixelSize: 13
                    text: "Private transactions on the Logos Execution Zone — amounts and participants stay hidden. One click creates your private wallet; after that it opens automatically." }
                Button { text: root.lezBusy ? "Working…" : "Create my private wallet"; enabled: !root.lezBusy; onClicked: root.lezOpen() }
                BusyIndicator { visible: root.lezBusy; running: visible; implicitWidth: 22; implicitHeight: 22 }
            }

            // Mnemonic (first run)
            Rectangle {
                Layout.fillWidth: true; visible: root.lezMnemonic.length > 0
                color: "#fff8e6"; border.color: "#f0d58c"; border.width: 1; radius: 8; implicitHeight: mn.implicitHeight + 20
                ColumnLayout {
                    id: mn
                    anchors { left: parent.left; right: parent.right; top: parent.top; margins: 10 }
                    spacing: 6
                    Text { Layout.fillWidth: true; wrapMode: Text.Wrap; color: "#7a5c00"; font.pixelSize: 12; text: "Recovery words — write them down, shown once:" }
                    Text { Layout.fillWidth: true; wrapMode: Text.Wrap; color: "#333"; font.pixelSize: 13; font.family: "Menlo"; text: root.lezMnemonic }
                    RowLayout { spacing: 8
                        Button { text: root.copied === "mn" ? "✓ Copied" : "⧉ Copy"; onClicked: root.copy(root.lezMnemonic, "mn") }
                        Button { text: "I saved them"; onClicked: root.lezMnemonic = "" }
                    }
                }
            }

            // Accounts — a LIST, each tagged Public/Private with its balance
            // (the stock-wallet model).
            Card {
                visible: root.lezReady; title: "ACCOUNTS"
                RowLayout {
                    Layout.fillWidth: true
                    Text {
                        text: "Total: " + root.fmt(root.lezAccountsList.reduce(function(a, x){ return a + (Number(x.balance)||0) }, 0))
                        color: "#234a86"; font.pixelSize: 16; font.weight: Font.DemiBold
                    }
                    Item { Layout.fillWidth: true }
                    Button { text: root.lezCreateBusy ? "…" : "+ Public"; enabled: !root.lezCreateBusy && !root.lezBusy; onClicked: root.lezCreateAccount("public") }
                    Button { text: root.lezCreateBusy ? "…" : "+ Private"; enabled: !root.lezCreateBusy && !root.lezBusy; onClicked: root.lezCreateAccount("private") }
                }
                Rectangle { Layout.fillWidth: true; height: 1; color: "#e5e8ec" }
                Text { visible: root.lezAccountsList.length === 0; text: "No accounts yet — create one above."; color: "#888"; font.pixelSize: 13 }
                Repeater {
                    model: root.lezAccountsList
                    delegate: RowLayout {
                        Layout.fillWidth: true; spacing: 8
                        // type badge
                        Rectangle {
                            radius: 4; color: modelData.isPublic ? "#e8f0fe" : "#f4effd"
                            implicitWidth: tp.implicitWidth + 12; implicitHeight: tp.implicitHeight + 6
                            Text { id: tp; anchors.centerIn: parent; text: modelData.isPublic ? "🌐 Public" : "🔒 Private"; color: modelData.isPublic ? "#234a86" : "#7a5fb0"; font.pixelSize: 11 }
                        }
                        Text { text: root.shortHex(modelData.idB58); color: "#333"; font.pixelSize: 12; font.family: "Menlo" }
                        ToolButton { text: root.copied === modelData.id ? "✓" : "⧉"; font.pixelSize: 12; onClicked: root.copy(modelData.idB58, modelData.id) }
                        // Private accounts: copy a receiving address to be paid privately.
                        ToolButton { visible: !modelData.isPublic; text: root.copied === "recv" ? "✓ addr" : "Receive"; font.pixelSize: 11; onClicked: root.lezCopyReceive(modelData.id) }
                        Item { Layout.fillWidth: true }
                        Text { text: root.fmt(modelData.balance); color: Number(modelData.balance) > 0 ? (modelData.isPublic ? "#188038" : "#7a5fb0") : "#888"; font.pixelSize: 14; font.weight: Font.DemiBold }
                    }
                }
                Text {
                    Layout.fillWidth: true; wrapMode: Text.Wrap; color: "#9aa5b1"; font.pixelSize: 11
                    text: "Public = transparent (visible on-chain). Private = shielded (only you can see it). Sync: " +
                          ((root.lezHeight >= 0 && root.lezLastSynced < root.lezHeight) ? (root.fmt(root.lezLastSynced) + "/" + root.fmt(root.lezHeight)) : (root.lezBusy ? (root.lezStage + "…") : "up to date"))
                }
                Text {
                    Layout.fillWidth: true; wrapMode: Text.Wrap; color: "#9aa5b1"; font.pixelSize: 11
                    text: "New accounts are derived from your wallet's recovery phrase — there's no separate key to save. Backing up that one phrase (shown when the wallet was created) recovers every account."
                }
                Text { visible: root.lezMsg.length > 0; Layout.fillWidth: true; wrapMode: Text.Wrap; text: "✓ " + root.lezMsg; color: "#188038"; font.pixelSize: 12 }
            }

            // Fund (pinata)
            Card {
                visible: root.lezReady; title: "GET TEST TOKENS"
                RowLayout {
                    Layout.fillWidth: true; spacing: 8
                    Button { text: root.lezBusy && root.lezStage === "mining" ? "Mining…" : "⛏ Get 150 free tokens"; enabled: !root.lezBusy; onClicked: root.lezFund() }
                    Text { Layout.fillWidth: true; wrapMode: Text.Wrap; text: "From the zone's proof-of-work faucet — instant, lands in your public account."; color: "#9aa5b1"; font.pixelSize: 11 }
                }
                RowLayout {
                    visible: Number(root.lezVault) > 0; Layout.fillWidth: true; spacing: 8
                    Text { text: root.fmt(root.lezVault) + " arrived from the base chain"; color: "#7a5fb0"; font.pixelSize: 13; font.weight: Font.DemiBold }
                    Button { text: "Claim to private"; enabled: !root.lezBusy; onClicked: root.lezClaimVault(root.lezVault) }
                }
                RowLayout {
                    visible: Number(root.lezPublicBalance) > 0; Layout.fillWidth: true; spacing: 8
                    Text { text: root.lezPublicBalance + " in your public account"; color: "#333"; font.pixelSize: 13 }
                    Button { text: root.lezBusy && root.lezStage === "transferring" ? "Shielding…" : "→ Shield to private"; enabled: !root.lezBusy && root.lezAccountHex.length === 64; onClicked: root.lezTransfer("shielded", "", root.lezAccountHex, root.lezPublicBalance) }
                }
            }

            // Transfer — explicit sender + recipient. The transfer kind
            // (shield / deshield / private / public) is derived from the
            // sender's type and the chosen recipient type, so the user never
            // has to reason about the jargon.
            Card {
                id: sendCard
                visible: root.lezReady; title: "SEND"

                // selected sender account (or null) + its balance
                property var fromAcct: (fromBox.currentIndex >= 0 && root.lezAccountsList.length > fromBox.currentIndex)
                                       ? root.lezAccountsList[fromBox.currentIndex] : null
                property double fromBal: fromAcct ? Number(fromAcct.balance) || 0 : 0
                property bool amtOver: Number(xferAmtField.text) > fromBal

                // FROM — pick which of my accounts pays
                RowLayout {
                    Layout.fillWidth: true; spacing: 8
                    Text { text: "From"; color: "#555"; font.pixelSize: 13; Layout.preferredWidth: 64 }
                    ComboBox {
                        id: fromBox; Layout.fillWidth: true; enabled: !root.lezBusy
                        model: root.lezAccountsList
                        currentIndex: root.lezAccountsList.length > 0 ? 0 : -1
                        displayText: fromBox.currentIndex >= 0 ? root.fromLabel(root.lezAccountsList[fromBox.currentIndex]) : "No accounts"
                        delegate: ItemDelegate { width: fromBox.width; text: root.fromLabel(modelData); font.pixelSize: 12 }
                    }
                }

                // TO — recipient address/id + its account type
                RowLayout {
                    Layout.fillWidth: true; spacing: 8
                    Text { text: "To"; color: "#555"; font.pixelSize: 13; Layout.preferredWidth: 64 }
                    TextField { id: xferToField; Layout.fillWidth: true
                        placeholderText: destTypeBox.currentValue ? "Recipient public account id…" : "Recipient's receiving address (lezpriv1…)"
                        enabled: !root.lezBusy; font.family: "Menlo"; font.pixelSize: 12 }
                    ComboBox { id: destTypeBox; Layout.preferredWidth: 130; enabled: !root.lezBusy; model: [
                        { t: "🔒 Private", pub: false },
                        { t: "🌐 Public",  pub: true } ]; textRole: "t"; valueRole: "pub" }
                }

                // AMOUNT + send
                RowLayout {
                    Layout.fillWidth: true; spacing: 8
                    Item { Layout.preferredWidth: 64 }
                    TextField { id: xferAmtField; Layout.preferredWidth: 120; placeholderText: "Amount"; enabled: !root.lezBusy; validator: RegularExpressionValidator { regularExpression: /[0-9]+/ } }
                    Text { text: "of " + root.fmt(sendCard.fromBal); color: "#9aa5b1"; font.pixelSize: 12 }
                    Item { Layout.fillWidth: true }
                    Button {
                        text: root.lezBusy ? "Sending…" : "Send"
                        enabled: !root.lezBusy && sendCard.fromAcct
                                 && root.validRecipient(xferToField.text, destTypeBox.currentValue)
                                 && Number(xferAmtField.text) > 0 && !sendCard.amtOver
                        onClicked: {
                            var f = sendCard.fromAcct
                            var destPub = destTypeBox.currentValue
                            var kind = root.xferKind(!!f.isPublic, destPub)
                            root.lezTransfer(kind, f.id, root.recipientArg(xferToField.text, destPub), xferAmtField.text.trim())
                        }
                    }
                }

                // Live preview of exactly what will happen
                Text {
                    visible: sendCard.fromAcct !== null
                    Layout.fillWidth: true; wrapMode: Text.Wrap; font.pixelSize: 12; color: "#234a86"
                    text: {
                        var f = sendCard.fromAcct; if (!f) return ""
                        var src = f.isPublic ? "🌐 public" : "🔒 private"
                        var dst = destTypeBox.currentValue ? "🌐 public" : "🔒 private"
                        var k = root.xferKind(!!f.isPublic, destTypeBox.currentValue)
                        var note = k === "private" ? " — amounts & parties hidden"
                                 : k === "shielded" ? " — becomes private"
                                 : k === "deshielded" ? " — becomes public" : " — visible on-chain"
                        return "Sends from your " + src + " account to a " + dst + " account" + note + "."
                    }
                }
                Text {
                    visible: sendCard.amtOver && Number(xferAmtField.text) > 0
                    text: "Amount exceeds this account's balance."; color: "#b26a00"; font.pixelSize: 11
                }
                Text {
                    visible: xferToField.text.trim().length > 0 && !root.validRecipient(xferToField.text, destTypeBox.currentValue)
                    text: destTypeBox.currentValue ? "That doesn't look like a valid account id."
                                                   : "For a private recipient, paste their receiving address (lezpriv1…). Your own private account id also works."
                    Layout.fillWidth: true; wrapMode: Text.Wrap; color: "#b26a00"; font.pixelSize: 11
                }
                Text { Layout.fillWidth: true; wrapMode: Text.Wrap
                    text: destTypeBox.currentValue
                        ? "Public transfers are visible on-chain. Recipient id can be base58 or hex."
                        : "Private transfers hide amounts and participants (proving takes up to a minute). To be paid privately, the recipient shares their receiving address via the “Receive” button on their private account."
                    color: "#9aa5b1"; font.pixelSize: 11 }

                // Clear the fields on a successful send. This lives inside the
                // tab Component so it can see xferToField (the root-level event
                // handler cannot — the ids are scoped to this Component).
                Connections {
                    target: (typeof logos !== "undefined") ? logos : null
                    function onModuleEventReceived(m, e, d) {
                        if (m !== "logos_wallet" || e !== "lezTransferFinished") return
                        var rr; try { rr = JSON.parse(d[0]) } catch (x) { rr = null }
                        if (rr && rr.ok) { xferToField.text = ""; xferAmtField.text = "" }
                    }
                }
            }

            // Bridge in
            Card {
                visible: root.lezReady && root.nodeStatus === 3; title: "BRIDGE FROM BASE CHAIN"
                RowLayout {
                    Layout.fillWidth: true; spacing: 8
                    TextField { id: bridgeAmtField; Layout.preferredWidth: 100; placeholderText: "Amount"; enabled: !root.lezBusy; validator: RegularExpressionValidator { regularExpression: /[0-9]+/ } }
                    Button { text: root.lezBusy && (root.lezStage === "depositing" || root.lezStage === "waiting-note") ? (root.lezStage + "…") : "⇩ Move base → private"; enabled: !root.lezBusy && Number(bridgeAmtField.text) > 0; onClicked: root.lezBridgeIn(bridgeAmtField.text.trim()) }
                }
                Text { Layout.fillWidth: true; wrapMode: Text.Wrap; text: "Moves base-chain tokens into your LEZ vault; credits after ~1h finality, then Claim above."; color: "#9aa5b1"; font.pixelSize: 11 }
            }
        }
    }
}
