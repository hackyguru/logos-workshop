// Easy Node — one-button Logos blockchain node.
//
// QML frontend for the sibling easy_node core module, which downloads and
// supervises the official logos-blockchain-node release binary (the logosup
// recipe, natively — no Docker, no CLI). The core owns the process
// lifecycle, keystore-derived addresses and inscriptions; everything else
// (chain status, peers, balances) is read here straight from the node's
// local HTTP API.
//
// Bridge API used:
//   logos.callModuleAsync(moduleId, method, args, cb)
//   logos.onModuleEvent(moduleId, eventName) + onModuleEventReceived
//
// easy_node returns QString JSON (the bridge can't serialize the LogosResult
// struct other modules return, and it JSON-encodes replies — parseReply
// unwraps both layers).

import QtQuick 2.15
import QtQuick.Controls 2.15
import QtQuick.Layouts 1.15

Item {
    id: root
    width: 660
    height: 940

    readonly property string faucetUrl: "https://testnet.blockchain.logos.co/web/faucet/"
    property string httpAddr: "127.0.0.1:18080"   // updated from easy_node status()

    // ── State ──────────────────────────────────────────────────────────────
    // 0 Off · 1 Setting up (download/config/start) · 3 Running
    property int    nodeStatus: 0
    property string stage: ""              // "downloading" | "configuring" | "starting"
    property bool   restarting: false      // supervised auto-restart in progress
    property bool   hasConfig: false
    property string lastError: ""
    property string chainMode: ""          // "Bootstrapping" | "Online"
    property double chainHeight: 0
    property double chainSlot: 0
    property var    accounts: []           // [{ role, address, balance (num|-1) }]
    property double totalBalance: 0
    property bool   balancesKnown: false
    property string peerId: ""
    property int    nPeers: -1             // -1 = unknown
    property int    nConnections: -1
    property int    pollTick: 0
    property string lastInscribeOut: ""
    property bool   inscribeBusy: false
    property bool   sendBusy: false
    property string lastSendTx: ""
    // LEZ private wallet
    property bool   lezReady: false
    property bool   lezHasWallet: false
    property bool   lezOpBusy: false       // pause polling: easy_node is inside a slow LEZ call
    property bool   lezSyncing: false
    property string lezAccount: ""
    property string lezBalance: ""
    property double lezLastSynced: -1
    property double lezHeight: -1
    property string lezMnemonic: ""
    property string copiedWhat: ""
    property bool   userStopped: false

    // ── Base58 (Bitcoin alphabet) — the LEZ account id display format.
    // Inlined from the stock wallet's Base58.js: the lgx packager only picks
    // up known file patterns, so a separate .js file never ships.
    readonly property string b58Alphabet: "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"

    function b58encode(hexStr) {
        if (!hexStr || hexStr.length === 0) return ""
        const clean = hexStr.toLowerCase().replace(/^0x/, "")
        if (clean.length === 0 || clean.length % 2 !== 0) return hexStr
        const bytes = []
        for (var i = 0; i < clean.length; i += 2)
            bytes.push(parseInt(clean.substr(i, 2), 16))
        var leadingZeros = 0
        while (leadingZeros < bytes.length && bytes[leadingZeros] === 0) leadingZeros++
        const digits = []
        for (i = 0; i < bytes.length; i++) {
            var carry = bytes[i]
            for (var j = 0; j < digits.length; j++) {
                carry += digits[j] * 256
                digits[j] = carry % 58
                carry = Math.floor(carry / 58)
            }
            while (carry > 0) { digits.push(carry % 58); carry = Math.floor(carry / 58) }
        }
        var result = "1".repeat(leadingZeros)
        for (i = digits.length - 1; i >= 0; i--) result += b58Alphabet[digits[i]]
        return result
    }

    function b58decode(b58Str) {
        if (!b58Str || b58Str.length === 0) return ""
        var leadingZeros = 0
        while (leadingZeros < b58Str.length && b58Str[leadingZeros] === "1") leadingZeros++
        const digits = []
        for (var i = 0; i < b58Str.length; i++) {
            const idx = b58Alphabet.indexOf(b58Str[i])
            if (idx < 0) return ""
            var carry = idx
            for (var j = 0; j < digits.length; j++) {
                carry += digits[j] * 58
                digits[j] = carry % 256
                carry = Math.floor(carry / 256)
            }
            while (carry > 0) { digits.push(carry % 256); carry = Math.floor(carry / 256) }
        }
        var hex = "00".repeat(leadingZeros)
        for (i = digits.length - 1; i >= 0; i--)
            hex += (digits[i] < 16 ? "0" : "") + digits[i].toString(16)
        return hex
    }

    // ── Bridge helpers ─────────────────────────────────────────────────────

    function callEn(method, args, cb) {
        if (typeof logos === "undefined" || !logos.callModuleAsync) {
            lastError = "Logos bridge unavailable — is this running inside Basecamp?"
            return
        }
        logos.callModuleAsync("easy_node", method, args,
                              function(raw) { cb(parseReply(raw)) })
    }

    // Bridge replies are JSON-encoded; easy_node's payload inside is JSON too.
    function parseReply(raw) {
        var v = raw
        for (var i = 0; i < 2 && typeof v === "string"; i++) {
            try { v = JSON.parse(v) } catch (e) { break }
        }
        if (v === null || v === undefined || typeof v !== "object")
            return { ok: false, error: "no reply from easy_node" }
        if (v.error !== undefined && v.ok === undefined)
            return { ok: false, error: String(v.error) }
        return v
    }

    function fail(msg) { lastError = msg; console.log("easy_node_ui: " + msg) }

    // ── Lifecycle ──────────────────────────────────────────────────────────

    // setupAndStart returns immediately ({accepted:true}); download +
    // config + node boot run inside easy_node and finish with a
    // setupFinished event. The poll timer tracks stage/running meanwhile.
    function setupAndStart() {
        lastError = ""
        userStopped = false
        nodeStatus = 1
        callEn("setupAndStart", [], function(r) {
            if (!r.ok) {
                nodeStatus = 0
                fail(r.error)
            }
        })
    }

    function onSetupFinished(resultJson) {
        var r
        try { r = JSON.parse(resultJson) } catch (e) { r = null }
        if (r && r.ok) {
            hasConfig = true
            nodeStatus = 3
            refreshAll()
        } else {
            nodeStatus = 0
            fail(r ? r.error : "Node setup failed.")
        }
    }

    function stopNode() {
        userStopped = true
        callEn("stopNode", [], function(r) {
            if (!r.ok) { fail(r.error); return }
            nodeStatus = 0
            restarting = false
            chainMode = ""; nPeers = -1; nConnections = -1
        })
    }

    // ── Polling ────────────────────────────────────────────────────────────

    function refreshCore() {
        callEn("status", [], function(r) {
            if (!r.ok) return
            hasConfig = !!r.hasConfig
            stage = String(r.stage || "")
            if (r.httpAddr) httpAddr = String(r.httpAddr)
            if (r.running) {
                nodeStatus = 3
                restarting = false
            } else if (nodeStatus === 3) {
                if (r.setupBusy) { nodeStatus = 1; return }
                if (!userStopped && Number(r.restarts) > 0) {
                    // Supervised restart in progress (0.2.0's IBD self-shutdown
                    // race near tip) — the core relaunches it automatically.
                    restarting = true
                } else {
                    nodeStatus = 0
                    chainMode = ""
                    if (r.setupError) fail(String(r.setupError))
                }
            } else if (nodeStatus === 1 && !r.setupBusy && !r.running) {
                nodeStatus = 0
                if (r.setupError) fail(String(r.setupError))
            }
        })
    }

    // Chain + peers proxied through easy_node (QML's XMLHttpRequest doesn't
    // work inside Basecamp's runtime, so the core curls the node's local
    // HTTP API for us).
    function refreshNodeInfo() {
        callEn("nodeInfo", [], function(r) {
            if (!r.ok) return
            if (r.chain && r.chain.cryptarchia_info) {
                const info = r.chain.cryptarchia_info
                chainHeight = Number(info.height || 0)
                chainSlot = Number(info.slot || 0)
                var m = r.chain.mode
                if (m && typeof m === "object") { for (var k in m) { m = m[k]; break } }
                chainMode = String(m || "")
            }
            if (r.net) {
                peerId = String(r.net.peer_id || "")
                nPeers = Number(r.net.n_peers)
                nConnections = Number(r.net.n_connections)
            } else {
                nPeers = -1; nConnections = -1
            }
        })
    }

    function refreshAccounts() {
        callEn("accounts", [], function(r) {
            if (!r.ok || !Array.isArray(r.accounts)) return
            var next = r.accounts.slice()
            // LeaderFunding first — it's the address the faucet should fund.
            next.sort(function(a, b) {
                return (b.role === "LeaderFunding") - (a.role === "LeaderFunding")
            })
            var total = 0, known = next.length > 0
            for (var i = 0; i < next.length; i++) {
                if (Number(next[i].balance) < 0) known = false
                else total += Number(next[i].balance)
            }
            accounts = next
            totalBalance = total
            balancesKnown = known
        })
    }

    function refreshAll() {
        // While easy_node executes a slow private-wallet call its event loop
        // is blocked; polling would only queue doomed IPC calls (whose
        // timeout path can crash the host). Wait for the finished event.
        if (lezOpBusy) return
        refreshCore()
        if (nodeStatus === 3) {
            refreshNodeInfo()
            if (accounts.length === 0 || pollTick % 4 === 0) refreshAccounts()
        }
        if (pollTick % 4 === 1) refreshLez()
    }

    // ── LEZ private wallet ─────────────────────────────────────────────
    function refreshLez() {
        callEn("lezStatus", [], function(r) {
            if (r.error !== undefined && r.ok === false) return
            lezReady = !!r.ready
            lezHasWallet = !!r.hasWallet
            lezSyncing = !!r.syncing
            lezAccount = String(r.account || "")
            lezBalance = String(r.balance || "")
            lezVault = String(r.vault || "")
            lezPublicBalance = String(r.publicBalance || "")
            lezBridgeStage = String(r.bridgeStage || "")
            lezLastSynced = Number(r.lastSynced !== undefined ? r.lastSynced : -1)
            lezHeight = Number(r.height !== undefined ? r.height : -1)
            // Behind the sequencer tip → pull the next sync chunk.
            if (lezReady && lezLastSynced >= 0 && lezHeight > lezLastSynced && !lezSyncing)
                callEn("lezSync", [], function() {})
        })
    }

    function lezSetup() {
        lastError = ""
        lezOpBusy = true
        callEn("lezSetup", [], function(r) {
            if (!r.ok) { lezOpBusy = false; fail(r.error) }
        })
    }

    function onLezSetupFinished(resultJson) {
        lezOpBusy = false
        var r
        try { r = JSON.parse(resultJson) } catch (e) { r = null }
        if (!r || !r.ok) { fail(r ? r.error : "Private wallet setup failed."); return }
        lezAccount = String(r.account || "")
        lezReady = lezAccount.length > 0
        if (r.mnemonic && r.mnemonic.length > 0) lezMnemonic = String(r.mnemonic)
        refreshLez()
    }

    function lezSend(toInput, amount) {
        lastError = ""
        // Accept a Base58 account id (what the LEZ wallet shows) or raw hex.
        var toHex = toInput.trim()
        if (!/^[0-9a-fA-F]{64}$/.test(toHex)) {
            try { toHex = b58decode(toInput.trim()) } catch (e) { toHex = "" }
        }
        if (!/^[0-9a-fA-F]{64}$/.test(toHex)) {
            fail("That doesn't look like a LEZ account id.")
            return
        }
        lezOpBusy = true
        callEn("lezTransfer", [toHex, amount], function(r) {
            if (!r.ok) { lezOpBusy = false; fail(r.error) }
        })
    }

    function lezBridge(direction, amount) {
        lastError = ""
        lastBridgeMsg = ""
        lezOpBusy = true
        callEn(direction, [amount], function(r) {
            if (!r.ok) { lezOpBusy = false; fail(r.error) }
        })
    }

    function onLezBridgeFinished(kind, resultJson) {
        lezOpBusy = false
        var r
        try { r = JSON.parse(resultJson) } catch (e) { r = null }
        if (!r || !r.ok) { fail(r ? r.error : "Bridge operation failed."); return }
        if (kind === "deposit")
            lastBridgeMsg = "Deposit sent (tx " + shortHex(String(r.tx || "")) + "). It reaches your "
                          + "private vault after the public chain finalizes it — roughly an hour on "
                          + "this testnet. A Claim button appears here when it arrives."
        else if (kind === "claim")
            lastBridgeMsg = "Claimed into your private balance ✓"
        else
            lastBridgeMsg = "Withdrawal submitted — tokens arrive at your ★ address after the zone "
                          + "batches it and the chain finalizes (~an hour)."
        bridgeAmountField.text = ""
        refreshLez()
    }

    function onLezMineFinished(resultJson) {
        lezOpBusy = false
        var r
        try { r = JSON.parse(resultJson) } catch (e) { r = null }
        if (!r || !r.ok) { fail(r ? r.error : "Mining failed."); return }
        lastBridgeMsg = "Mined " + (r.prize || 150) + " free tokens into your private balance ✓"
        refreshLez()
    }

    function onLezTransferFinished(resultJson) {
        lezOpBusy = false
        var r
        try { r = JSON.parse(resultJson) } catch (e) { r = null }
        if (!r || !r.ok) { fail(r ? r.error : "Private transfer failed."); return }
        lezSendToField.text = ""; lezSendAmountField.text = ""
        lastLezSend = "sent privately ✓"
        refreshLez()
    }
    property string lastLezSend: ""
    property string lezPublicBalance: ""
    property string lezVault: ""
    property string lezBridgeStage: ""
    property string lastBridgeMsg: ""

    Timer {
        interval: 2500
        running: root.nodeStatus >= 1
        repeat: true
        onTriggered: { root.pollTick++; root.refreshAll() }
    }

    Connections {
        target: (typeof logos !== "undefined") ? logos : null
        function onModuleEventReceived(moduleName, eventName, data) {
            if (moduleName !== "easy_node") return
            if (eventName === "setupFinished") root.onSetupFinished(data[0])
            else if (eventName === "inscribeFinished") root.onInscribeFinished(data[0])
            else if (eventName === "lezSetupFinished") root.onLezSetupFinished(data[0])
            else if (eventName === "lezTransferFinished") root.onLezTransferFinished(data[0])
            else if (eventName === "lezSyncFinished") { root.lezOpBusy = false; root.refreshLez() }
            else if (eventName === "lezDepositFinished") root.onLezBridgeFinished("deposit", data[0])
            else if (eventName === "lezClaimFinished") root.onLezBridgeFinished("claim", data[0])
            else if (eventName === "lezWithdrawFinished") root.onLezBridgeFinished("withdraw", data[0])
            else if (eventName === "lezMineFinished") root.onLezMineFinished(data[0])
        }
    }

    Component.onCompleted: {
        if (typeof logos !== "undefined" && logos.onModuleEvent) {
            logos.onModuleEvent("easy_node", "setupFinished")
            logos.onModuleEvent("easy_node", "inscribeFinished")
            logos.onModuleEvent("easy_node", "lezSetupFinished")
            logos.onModuleEvent("easy_node", "lezSyncFinished")
            logos.onModuleEvent("easy_node", "lezTransferFinished")
            logos.onModuleEvent("easy_node", "lezDepositFinished")
            logos.onModuleEvent("easy_node", "lezClaimFinished")
            logos.onModuleEvent("easy_node", "lezWithdrawFinished")
            logos.onModuleEvent("easy_node", "lezMineFinished")
        }
        refreshCore()
    }

    // ── Inscribe ───────────────────────────────────────────────────────────

    function inscribe(text) {
        lastError = ""
        inscribeBusy = true
        callEn("inscribe", [text], function(r) {
            if (!r.ok) { inscribeBusy = false; fail(r.error) }
            // Success reply only means "accepted" — result arrives via the
            // inscribeFinished event.
        })
    }

    function onInscribeFinished(resultJson) {
        inscribeBusy = false
        var r
        try { r = JSON.parse(resultJson) } catch (e) { r = null }
        if (!r || !r.ok) { fail(r ? r.error : "Inscription failed."); return }
        lastInscribeOut = r.tip ? "confirmed on-chain · message " + shortHex(String(r.tip))
                                : String(r.output || "published")
        inscribeField.text = ""
        refreshAccounts()
    }

    function fundedAddress() {
        for (var i = 0; i < accounts.length; i++)
            if (Number(accounts[i].balance) > 0) return accounts[i].address
        return ""
    }

    function sendTokens(to, amount) {
        lastError = ""
        const from = fundedAddress()
        if (from === "") { fail("No funded address to send from."); return }
        sendBusy = true
        callEn("transfer", [from, to, amount], function(r) {
            sendBusy = false
            if (!r.ok) { fail(r.error); return }
            lastSendTx = String(r.tx || "")
            sendToField.text = ""; sendAmountField.text = ""
            refreshAccounts()
        })
    }

    // ── Display helpers ────────────────────────────────────────────────────

    function shortHex(h) {
        return h.length > 20 ? h.substring(0, 10) + "…" + h.substring(h.length - 8) : h
    }
    function fmtAmount(n) {
        return (n < 0) ? "…" : Number(n).toLocaleString(Qt.locale(), 'f', 0)
    }
    function statusLabel() {
        if (nodeStatus === 1)
            return stage === "downloading"  ? "Downloading the Logos node…"
                 : stage === "configuring"  ? "Creating your node and wallet…"
                 : "Starting…"
        if (nodeStatus === 3) {
            if (restarting) return "Restarting…"
            return chainMode === "Online" ? "Online"
                 : chainMode.length > 0   ? "Syncing…" : "Running"
        }
        return "Off"
    }
    function statusColor() {
        if (nodeStatus === 3 && !restarting)
            return chainMode === "Online" ? "#188038" : "#b26a00"
        if (nodeStatus > 0) return "#b26a00"
        return "#9aa5b1"
    }

    TextEdit { id: clip; visible: false }
    function copyText(t, label) {
        clip.text = t; clip.selectAll(); clip.copy()
        copiedWhat = label
        copiedTimer.restart()
    }
    Timer { id: copiedTimer; interval: 1600; onTriggered: root.copiedWhat = "" }

    // ── UI ─────────────────────────────────────────────────────────────────

    Flickable {
        anchors.fill: parent
        anchors.margins: 16
        contentWidth: width
        contentHeight: column.height
        clip: true

        ColumnLayout {
            id: column
            width: parent.width
            spacing: 12

            // Header
            RowLayout {
                Layout.fillWidth: true
                spacing: 10
                Rectangle { width: 12; height: 12; radius: 6; color: root.statusColor() }
                Text { text: "Logos Node"; font.pixelSize: 20; font.weight: Font.DemiBold; color: "#333" }
                Text { text: root.statusLabel(); color: "#666"; font.pixelSize: 14 }
                Item { Layout.fillWidth: true }
                Button {
                    visible: root.nodeStatus === 3
                    text: "Stop"
                    onClicked: root.stopNode()
                }
            }

            // Error banner
            Rectangle {
                Layout.fillWidth: true
                visible: root.lastError.length > 0
                color: "#fdecea"; border.color: "#f5b7b1"; border.width: 1; radius: 8
                implicitHeight: errText.implicitHeight + 20
                Text {
                    id: errText
                    anchors.fill: parent; anchors.margins: 10
                    text: root.lastError
                    wrapMode: Text.Wrap
                    color: "#8a1f11"; font.pixelSize: 13
                }
            }

            // ── Off state: the one button ─────────────────────────────────
            Rectangle {
                Layout.fillWidth: true
                visible: root.nodeStatus !== 3
                color: "#eef4ff"; border.color: "#a9c7f0"; border.width: 1; radius: 10
                implicitHeight: offCol.implicitHeight + 40

                ColumnLayout {
                    id: offCol
                    anchors.centerIn: parent
                    width: parent.width - 48
                    spacing: 14

                    Text {
                        Layout.fillWidth: true
                        horizontalAlignment: Text.AlignHCenter
                        text: root.hasConfig
                              ? "Your node is set up and ready."
                              : "Run your own Logos blockchain node.\nOne click installs the node and creates your wallet — no setup needed."
                        wrapMode: Text.Wrap
                        color: "#234a86"; font.pixelSize: 15
                    }
                    Button {
                        Layout.alignment: Qt.AlignHCenter
                        enabled: root.nodeStatus === 0
                        text: root.nodeStatus === 1
                              ? root.statusLabel()
                              : (root.hasConfig ? "▶  Start my node" : "▶  Install and start my node")
                        font.pixelSize: 16
                        padding: 14
                        onClicked: root.setupAndStart()
                    }
                    BusyIndicator {
                        Layout.alignment: Qt.AlignHCenter
                        visible: root.nodeStatus === 1
                        running: visible
                        implicitWidth: 28; implicitHeight: 28
                    }
                }
            }

            // ── Node info card ────────────────────────────────────────────
            Rectangle {
                Layout.fillWidth: true
                visible: root.nodeStatus === 3
                color: "#f8f9fa"; border.color: "#dfe3e8"; border.width: 1; radius: 8
                implicitHeight: nodeCol.implicitHeight + 24

                ColumnLayout {
                    id: nodeCol
                    anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top
                    anchors.margins: 12
                    spacing: 8

                    Text { text: "NODE"; color: "#9aa5b1"; font.pixelSize: 11; font.weight: Font.DemiBold }

                    GridLayout {
                        Layout.fillWidth: true
                        columns: 2
                        columnSpacing: 24
                        rowSpacing: 6

                        Text { text: "Status"; color: "#555"; font.pixelSize: 13 }
                        Text {
                            text: root.restarting ? "Restarting (normal while catching up)…"
                                : root.chainMode === "Online" ? "Online — following the chain live"
                                : root.chainMode.length > 0 ? "Syncing the blockchain…"
                                : "Running"
                            color: root.statusColor(); font.pixelSize: 13; font.weight: Font.DemiBold
                        }

                        Text { text: "Block height"; color: "#555"; font.pixelSize: 13 }
                        Text { text: root.fmtAmount(root.chainHeight) + "   (slot " + root.fmtAmount(root.chainSlot) + ")"; color: "#333"; font.pixelSize: 13 }

                        Text { text: "Peers connected"; color: "#555"; font.pixelSize: 13 }
                        Text {
                            text: root.nPeers >= 0
                                  ? root.nPeers + " peers · " + root.nConnections + " connections"
                                  : "—"
                            color: "#333"; font.pixelSize: 13
                        }

                        Text { text: "Peer ID"; color: "#555"; font.pixelSize: 13 }
                        RowLayout {
                            spacing: 6
                            Text {
                                text: root.peerId.length > 0 ? root.shortHex(root.peerId) : "—"
                                color: "#333"; font.pixelSize: 13; font.family: "Menlo"
                            }
                            ToolButton {
                                visible: root.peerId.length > 0
                                text: root.copiedWhat === "peer" ? "✓" : "⧉"
                                font.pixelSize: 12
                                onClicked: root.copyText(root.peerId, "peer")
                            }
                        }
                    }
                }
            }

            // ── Wallet card ───────────────────────────────────────────────
            Rectangle {
                Layout.fillWidth: true
                visible: root.nodeStatus === 3
                color: "#f8f9fa"; border.color: "#dfe3e8"; border.width: 1; radius: 8
                implicitHeight: walletCol.implicitHeight + 24

                ColumnLayout {
                    id: walletCol
                    anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top
                    anchors.margins: 12
                    spacing: 8

                    RowLayout {
                        Layout.fillWidth: true
                        Text { text: "WALLET"; color: "#9aa5b1"; font.pixelSize: 11; font.weight: Font.DemiBold }
                        Item { Layout.fillWidth: true }
                        Text {
                            text: "Total: " + (root.balancesKnown ? root.fmtAmount(root.totalBalance) : "…")
                            color: "#234a86"; font.pixelSize: 14; font.weight: Font.DemiBold
                        }
                    }

                    Text {
                        visible: root.accounts.length === 0
                        text: "Loading wallet…"
                        color: "#888"; font.pixelSize: 13
                    }

                    Repeater {
                        model: root.accounts
                        delegate: RowLayout {
                            Layout.fillWidth: true
                            spacing: 6
                            Text {
                                text: (modelData.role === "LeaderFunding" ? "★ " : "")
                                      + root.shortHex(modelData.address)
                                color: "#333"; font.pixelSize: 13; font.family: "Menlo"
                            }
                            Text {
                                text: modelData.role
                                color: "#9aa5b1"; font.pixelSize: 11
                            }
                            ToolButton {
                                text: root.copiedWhat === modelData.address ? "✓ copied" : "⧉ copy"
                                font.pixelSize: 12
                                onClicked: root.copyText(modelData.address, modelData.address)
                            }
                            Item { Layout.fillWidth: true }
                            Text {
                                text: root.fmtAmount(modelData.balance)
                                color: modelData.balance > 0 ? "#188038" : "#555"
                                font.pixelSize: 13; font.weight: Font.DemiBold
                            }
                        }
                    }

                    // Faucet nudge — only while everything is empty
                    Rectangle {
                        Layout.fillWidth: true
                        visible: root.balancesKnown && root.totalBalance === 0 && root.accounts.length > 0
                        color: "#fff8e6"; border.color: "#f0d58c"; border.width: 1; radius: 8
                        implicitHeight: faucetCol.implicitHeight + 20

                        ColumnLayout {
                            id: faucetCol
                            anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top
                            anchors.margins: 10
                            spacing: 8
                            Text {
                                Layout.fillWidth: true
                                text: "Your wallet is empty. Get free test tokens: copy your ★ address, open the faucet, paste it into “Destination Public Key (Hex)” and press “Request Funds”. Tokens arrive in a minute or two."
                                wrapMode: Text.Wrap
                                color: "#7a5c00"; font.pixelSize: 12
                            }
                            RowLayout {
                                spacing: 8
                                Button {
                                    text: root.copiedWhat === "addr0" ? "✓ Address copied" : "⧉ Copy my address"
                                    onClicked: if (root.accounts.length > 0) root.copyText(root.accounts[0].address, "addr0")
                                }
                                Button {
                                    text: "Open faucet ↗"
                                    onClicked: Qt.openUrlExternally(root.faucetUrl)
                                }
                            }
                        }
                    }
                }
            }

            // ── Send card ─────────────────────────────────────────────────
            Rectangle {
                Layout.fillWidth: true
                visible: root.nodeStatus === 3
                color: "#f8f9fa"; border.color: "#dfe3e8"; border.width: 1; radius: 8
                implicitHeight: sendCol.implicitHeight + 24

                ColumnLayout {
                    id: sendCol
                    anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top
                    anchors.margins: 12
                    spacing: 8

                    Text { text: "SEND"; color: "#9aa5b1"; font.pixelSize: 11; font.weight: Font.DemiBold }
                    Text {
                        Layout.fillWidth: true
                        text: "Send tokens from your ★ address to any Logos address."
                        wrapMode: Text.Wrap
                        color: "#555"; font.pixelSize: 13
                    }

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 8
                        TextField {
                            id: sendToField
                            Layout.fillWidth: true
                            placeholderText: "Recipient address (64 hex characters)…"
                            enabled: !root.sendBusy
                            font.family: "Menlo"; font.pixelSize: 12
                        }
                        TextField {
                            id: sendAmountField
                            Layout.preferredWidth: 110
                            placeholderText: "Amount"
                            enabled: !root.sendBusy
                            validator: RegularExpressionValidator { regularExpression: /[0-9]+/ }
                        }
                        Button {
                            text: root.sendBusy ? "Sending…" : "Send"
                            enabled: !root.sendBusy
                                     && /^[0-9a-fA-F]{64}$/.test(sendToField.text.trim())
                                     && Number(sendAmountField.text) > 0
                                     && root.fundedAddress() !== ""
                            onClicked: root.sendTokens(sendToField.text.trim(), sendAmountField.text.trim())
                        }
                    }

                    Text {
                        visible: root.balancesKnown && root.fundedAddress() === ""
                        text: "Needs funds — get test tokens above first."
                        color: "#b26a00"; font.pixelSize: 12
                    }
                    RowLayout {
                        visible: root.lastSendTx.length > 0
                        spacing: 6
                        Text { text: "✓ Sent! Transaction:"; color: "#188038"; font.pixelSize: 12 }
                        Text {
                            text: root.shortHex(root.lastSendTx)
                            color: "#333"; font.pixelSize: 12; font.family: "Menlo"
                        }
                        ToolButton {
                            text: root.copiedWhat === "sendtx" ? "✓" : "⧉"
                            font.pixelSize: 12
                            onClicked: root.copyText(root.lastSendTx, "sendtx")
                        }
                    }
                }
            }

            // ── Inscribe card ─────────────────────────────────────────────
            Rectangle {
                Layout.fillWidth: true
                visible: root.nodeStatus === 3
                color: "#f8f9fa"; border.color: "#dfe3e8"; border.width: 1; radius: 8
                implicitHeight: inscribeCol.implicitHeight + 24

                ColumnLayout {
                    id: inscribeCol
                    anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top
                    anchors.margins: 12
                    spacing: 8

                    Text { text: "INSCRIBE"; color: "#9aa5b1"; font.pixelSize: 11; font.weight: Font.DemiBold }
                    Text {
                        Layout.fillWidth: true
                        text: "Write a short message permanently onto the Logos blockchain."
                        wrapMode: Text.Wrap
                        color: "#555"; font.pixelSize: 13
                    }

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 8
                        TextField {
                            id: inscribeField
                            Layout.fillWidth: true
                            placeholderText: "Your message…"
                            enabled: !root.inscribeBusy
                            onAccepted: if (text.trim().length > 0 && !root.inscribeBusy && !root.restarting)
                                            root.inscribe(text.trim())
                        }
                        Button {
                            text: root.inscribeBusy ? "Inscribing…" : "Inscribe"
                            enabled: !root.inscribeBusy && !root.restarting
                                     && inscribeField.text.trim().length > 0
                            onClicked: root.inscribe(inscribeField.text.trim())
                        }
                    }

                    RowLayout {
                        visible: root.lastInscribeOut.length > 0
                        spacing: 6
                        Text { text: "✓ Inscribed!"; color: "#188038"; font.pixelSize: 12 }
                        Text {
                            Layout.fillWidth: true
                            text: root.lastInscribeOut
                            elide: Text.ElideRight
                            color: "#555"; font.pixelSize: 12; font.family: "Menlo"
                        }
                    }
                }
            }

            // ── Private (LEZ) card ────────────────────────────────────────
            Rectangle {
                Layout.fillWidth: true
                visible: root.nodeStatus === 3 || root.lezReady
                color: "#f4effd"; border.color: "#cdbdf0"; border.width: 1; radius: 8
                implicitHeight: lezCol.implicitHeight + 24

                ColumnLayout {
                    id: lezCol
                    anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top
                    anchors.margins: 12
                    spacing: 8

                    RowLayout {
                        Layout.fillWidth: true
                        Text { text: "PRIVATE (LEZ)"; color: "#7a5fb0"; font.pixelSize: 11; font.weight: Font.DemiBold }
                        Item { Layout.fillWidth: true }
                        Text {
                            visible: root.lezReady
                            text: root.lezOpBusy ? "working…"
                                : (root.lezHeight >= 0 && root.lezLastSynced < root.lezHeight)
                                    ? "syncing " + root.fmtAmount(root.lezLastSynced) + " / " + root.fmtAmount(root.lezHeight)
                                    : "up to date"
                            color: "#7a5fb0"; font.pixelSize: 11
                        }
                    }

                    // Not set up yet
                    ColumnLayout {
                        visible: !root.lezReady
                        Layout.fillWidth: true
                        spacing: 8
                        Text {
                            Layout.fillWidth: true
                            text: "Private transactions live on the Logos Execution Zone (LEZ) — amounts and participants stay hidden. One click creates your private account."
                            wrapMode: Text.Wrap
                            color: "#555"; font.pixelSize: 13
                        }
                        Button {
                            text: root.lezOpBusy ? "Setting up…"
                                : root.lezHasWallet ? "Open my private wallet" : "Create my private account"
                            enabled: !root.lezOpBusy
                            onClicked: root.lezSetup()
                        }
                    }

                    // Mnemonic reveal (first run only)
                    Rectangle {
                        Layout.fillWidth: true
                        visible: root.lezMnemonic.length > 0
                        color: "#fff8e6"; border.color: "#f0d58c"; border.width: 1; radius: 8
                        implicitHeight: mnCol.implicitHeight + 20
                        ColumnLayout {
                            id: mnCol
                            anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top
                            anchors.margins: 10
                            spacing: 6
                            Text {
                                Layout.fillWidth: true
                                text: "Recovery words for your private wallet — write them down, they are shown only once:"
                                wrapMode: Text.Wrap; color: "#7a5c00"; font.pixelSize: 12
                            }
                            Text {
                                Layout.fillWidth: true
                                text: root.lezMnemonic
                                wrapMode: Text.Wrap; color: "#333"; font.pixelSize: 13; font.family: "Menlo"
                            }
                            RowLayout {
                                spacing: 8
                                Button {
                                    text: root.copiedWhat === "mnemonic" ? "✓ Copied" : "⧉ Copy"
                                    onClicked: root.copyText(root.lezMnemonic, "mnemonic")
                                }
                                Button { text: "I saved them"; onClicked: root.lezMnemonic = "" }
                            }
                        }
                    }

                    // Ready: account + balance + private send
                    ColumnLayout {
                        visible: root.lezReady
                        Layout.fillWidth: true
                        spacing: 8

                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 6
                            Text { text: "My private account"; color: "#555"; font.pixelSize: 13 }
                            Text {
                                text: root.shortHex(root.b58encode(root.lezAccount))
                                color: "#333"; font.pixelSize: 13; font.family: "Menlo"
                            }
                            ToolButton {
                                text: root.copiedWhat === "lezacct" ? "✓" : "⧉"
                                font.pixelSize: 12
                                onClicked: root.copyText(root.b58encode(root.lezAccount), "lezacct")
                            }
                            Item { Layout.fillWidth: true }
                            Text {
                                text: "Balance: " + (root.lezBalance.length > 0 ? root.lezBalance : "…")
                                      + (Number(root.lezPublicBalance) > 0
                                         ? "  (+" + root.lezPublicBalance + " unshielded)" : "")
                                color: "#7a5fb0"; font.pixelSize: 14; font.weight: Font.DemiBold
                            }
                        }

                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 8
                            TextField {
                                id: lezSendToField
                                Layout.fillWidth: true
                                placeholderText: "Recipient LEZ account id…"
                                enabled: !root.lezOpBusy
                                font.family: "Menlo"; font.pixelSize: 12
                            }
                            TextField {
                                id: lezSendAmountField
                                Layout.preferredWidth: 110
                                placeholderText: "Amount"
                                enabled: !root.lezOpBusy
                                validator: RegularExpressionValidator { regularExpression: /[0-9]+/ }
                            }
                            Button {
                                text: root.lezOpBusy ? "Sending…" : "Send privately"
                                enabled: !root.lezOpBusy
                                         && lezSendToField.text.trim().length > 0
                                         && Number(lezSendAmountField.text) > 0
                                onClicked: root.lezSend(lezSendToField.text, lezSendAmountField.text.trim())
                            }
                        }

                        Text {
                            visible: root.lastLezSend.length > 0
                            text: "✓ " + root.lastLezSend
                            color: "#188038"; font.pixelSize: 12
                        }
                        // Vault claim (bridged deposits land here after L1 finality)
                        RowLayout {
                            visible: Number(root.lezVault) > 0
                            Layout.fillWidth: true
                            spacing: 8
                            Text {
                                text: root.fmtAmount(root.lezVault) + " arrived from the public chain"
                                color: "#7a5fb0"; font.pixelSize: 13; font.weight: Font.DemiBold
                            }
                            Button {
                                text: root.lezOpBusy ? "Claiming…" : "Claim into private balance"
                                enabled: !root.lezOpBusy
                                onClicked: root.lezBridge("lezClaimVault", root.lezVault)
                            }
                        }

                        // Pinata: the zone's built-in PoW faucet — free private tokens
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 8
                            Button {
                                text: root.lezOpBusy && root.lezBridgeStage === "mining"
                                      ? "Mining… (up to a minute)" : "⛏  Get free private tokens"
                                enabled: !root.lezOpBusy
                                onClicked: { root.lastError = ""; root.lastBridgeMsg = ""; root.lezOpBusy = true
                                             root.callEn("lezMine", [], function(r) {
                                                 if (!r.ok) { root.lezOpBusy = false; root.fail(r.error) }
                                             }) }
                            }
                            Text {
                                Layout.fillWidth: true
                                text: "150 per claim, from the zone's proof-of-work faucet — instant, no bridge needed."
                                wrapMode: Text.Wrap
                                color: "#9aa5b1"; font.pixelSize: 11
                            }
                        }

                        // Bridge: base chain ⇄ private
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 8
                            TextField {
                                id: bridgeAmountField
                                Layout.preferredWidth: 110
                                placeholderText: "Amount"
                                enabled: !root.lezOpBusy
                                validator: RegularExpressionValidator { regularExpression: /[0-9]+/ }
                            }
                            Button {
                                text: root.lezOpBusy && root.lezBridgeStage.length > 0
                                      ? root.lezBridgeStage + "…" : "⇩ From ★ to private"
                                enabled: !root.lezOpBusy && Number(bridgeAmountField.text) > 0
                                onClicked: root.lezBridge("lezDeposit", bridgeAmountField.text.trim())
                            }
                            Button {
                                text: "⇧ From private to ★"
                                enabled: !root.lezOpBusy && Number(bridgeAmountField.text) > 0
                                         && Number(root.lezBalance) >= Number(bridgeAmountField.text)
                                onClicked: root.lezBridge("lezWithdraw", bridgeAmountField.text.trim())
                            }
                        }

                        Text {
                            visible: root.lastBridgeMsg.length > 0
                            Layout.fillWidth: true
                            text: "✓ " + root.lastBridgeMsg
                            wrapMode: Text.Wrap
                            color: "#188038"; font.pixelSize: 12
                        }

                        Text {
                            Layout.fillWidth: true
                            text: "Share your account id to receive. Private transfers hide amounts and participants; sending takes up to a minute (zero-knowledge proof). Bridging to/from the public chain takes about an hour (chain finality)."
                            wrapMode: Text.Wrap
                            color: "#9aa5b1"; font.pixelSize: 11
                        }
                    }
                }
            }

            Item { height: 8 }
        }
    }
}
