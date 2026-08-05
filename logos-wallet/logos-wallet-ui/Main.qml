// Persona — Bedrock (base chain) + LEZ (private execution zone) in one
// tab bar. QML frontend for the logos_wallet core, which owns the node
// daemon and drives the version-matched logos_execution_zone module for all
// LEZ writes. All calls go through callModuleAsync; slow ops return
// {accepted:true} and finish via <name>Finished events (see the core).
//
// Visuals follow the Basecamp design system (Logos.Theme + Logos.Controls).
// Copy keeps the fundamental terms (base chain, LEZ, node, shield, faucet)
// and explains them in plain language alongside, instead of renaming them.

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

import Logos.Theme
import Logos.Controls

Rectangle {
    id: root
    width: 720
    height: 940
    color: Theme.palette.background

    property int tab: 0                       // 0 = Bedrock, 1 = LEZ

    // ── Bedrock state ────────────────────────────────────────────────
    property int nodeStatus: 0             // 0 off, 1 setting up, 3 running
    property bool baseStatusKnown: false   // first nodeStatus reply has landed
    property int _baseMisses: 0            // consecutive "not running" polls
    property string nodeStage: ""
    property string chainMode: ""
    property double chainHeight: 0
    property double chainSlot: 0
    property int nPeers: -1
    property int nConnections: -1
    property string peerId: ""
    property string httpAddr: ""           // node's local HTTP API address
    property string nodeVersion: ""        // node binary version
    property var baseAccounts: []
    property string lastSendTx: ""
    property bool sendBusy: false
    property string lastInscribe: ""
    property bool inscribeBusy: false
    property var inscFeed: []                 // recent text inscriptions (anyone's)
    property bool inscFeedLoading: false
    property bool inscFeedLoaded: false
    property var recentBlocksList: []         // recent base-chain blocks
    property bool blocksLoading: false

    // ── LEZ state ────────────────────────────────────────────────────
    property bool lezReady: false
    property bool lezHasWallet: false
    property bool lezBusy: false
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
    property var lezAccountsList: []
    property bool lezCreateBusy: false
    property bool lezStatusKnown: false     // first lezStatus reply has landed
    property bool lezAutoOpened: false       // auto-open attempted this session
    property bool lezNeedsRestart: false      // reset done; old wallet still in memory
    // Configurable LEZ sequencer endpoint (settings dialog).
    property string lezSeqUrl: ""             // current effective sequencer URL
    property string lezSeqDefault: ""         // built-in default (for "Reset")
    property bool lezSeqIsDefault: true       // current == default
    property bool lezSeqBusy: false           // save in flight
    // First-run onboarding (create-with-seed / import) for the private wallet.
    property bool onbActive: false            // onboarding overlay is showing
    property int onbStep: 0                    // 0 choose · 1 seed · 2 verify · 3 import
    property var onbVerifyIdx: []             // word positions to confirm at verify
    property bool onbSaved: false             // user ticked "I saved my phrase"
    property bool onbPreview: false           // dev: walk the flow without touching the wallet
    property bool baseAccountsLoaded: false   // first baseAccounts reply landed
    property bool lezAccountsLoaded: false    // first lezAccounts reply landed
    property string _lezAccountsJson: ""       // change-guard for the accounts list
    property string _baseAccountsJson: ""      // change-guard for base accounts

    property string lastError: ""
    property string copied: ""
    property int tick: 0

    // ── Bridge helpers ───────────────────────────────────────────────
    function call(method, args, cb) {
        if (typeof logos === "undefined" || !logos.callModuleAsync) {
            lastError = "Logos bridge unavailable.";
            return;
        }
        logos.callModuleAsync("persona_core", method, args, function (raw) {
            cb(parse(raw));
        });
    }
    function parse(raw) {
        var v = raw;
        for (var i = 0; i < 2 && typeof v === "string"; i++) {
            try {
                v = JSON.parse(v);
            } catch (e) {
                break;
            }
        }
        if (v === null || typeof v !== "object")
            return {
                ok: false,
                error: "no reply"
            };
        // Treat only a NON-EMPTY error as a failure. Status replies (lezStatus)
        // legitimately carry an empty "error":"" alongside their fields and no
        // "ok" — those must pass through, not be swallowed as errors.
        if (v.error !== undefined && String(v.error) !== "" && v.ok === undefined)
            return {
                ok: false,
                error: String(v.error)
            };
        return v;
    }
    function fail(m) {
        lastError = m;
    }

    // Base58 (Bitcoin alphabet) decode → hex. Account ids are shown/copied as
    // base58, but the core expects 64-hex, so normalize before sending.
    readonly property string b58Alpha: "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
    function b58decode(str) {
        if (!str || str.length === 0)
            return "";
        var zeros = 0;
        while (zeros < str.length && str[zeros] === "1")
            zeros++;
        var digits = [];
        for (var i = 0; i < str.length; i++) {
            var idx = b58Alpha.indexOf(str[i]);
            if (idx < 0)
                return "";
            var carry = idx;
            for (var j = 0; j < digits.length; j++) {
                carry += digits[j] * 58;
                digits[j] = carry % 256;
                carry = Math.floor(carry / 256);
            }
            while (carry > 0) {
                digits.push(carry % 256);
                carry = Math.floor(carry / 256);
            }
        }
        var hex = "";
        for (var k = 0; k < zeros; k++)
            hex += "00";
        for (var m2 = digits.length - 1; m2 >= 0; m2--)
            hex += (digits[m2] < 16 ? "0" : "") + digits[m2].toString(16);
        return hex;
    }
    // Accept a base58 OR hex account id → 64-hex, or "" if not valid.
    function acctHex(input) {
        var s = (input || "").trim();
        if (/^[0-9a-fA-F]{64}$/.test(s))
            return s.toLowerCase();
        var h = b58decode(s);
        return /^[0-9a-fA-F]{64}$/.test(h) ? h.toLowerCase() : "";
    }

    // ── Bedrock actions ──────────────────────────────────────────────
    function startNode() {
        lastError = "";
        nodeStatus = 1;
        call("startNode", [], function (r) {
            if (!r.ok) {
                nodeStatus = 0;
                fail(r.error);
            }
        });
    }
    function stopNode() {
        call("stopNode", [], function (r) {
            nodeStatus = 0;
            chainMode = "";
            nPeers = -1;
            baseAccounts = [];
            baseAccountsLoaded = false;
        });
    }
    function baseSend(from, to, amt) {
        lastError = "";
        sendBusy = true;
        call("baseSend", [from, to, amt], function (r) {
            sendBusy = false;
            if (!r.ok) {
                fail(r.error);
                return;
            }
            lastSendTx = String(r.tx || "");
            sendToField.text = "";
            sendAmtField.text = "";
            refreshBase();
        });
    }
    function inscribe(t) {
        lastError = "";
        inscribeBusy = true;
        call("inscribe", [t], function (r) {
            if (!r.ok) {
                inscribeBusy = false;
                fail(r.error);
            }
        });
    }
    // Load the recent-inscriptions feed (anyone's text inscriptions). Result
    // arrives via the recentInscriptionsFinished event.
    function loadInscFeed() {
        if (inscFeedLoading || nodeStatus !== 3)
            return;
        inscFeedLoading = true;
        call("recentInscriptions", [], function (r) {
            if (!r.ok || (r.accepted === false && !Array.isArray(r.inscriptions)))
                inscFeedLoading = false;
        });
    }
    // Load the recent-blocks list (mini explorer). Result arrives via the
    // recentBlocksFinished event.
    function loadRecentBlocks() {
        if (blocksLoading || nodeStatus !== 3)
            return;
        blocksLoading = true;
        call("recentBlocks", [], function (r) {
            if (!r.ok || (r.accepted === false && !Array.isArray(r.blocks)))
                blocksLoading = false;
        });
    }

    // ── LEZ actions ──────────────────────────────────────────────────
    function lezOpen() {
        lastError = "";
        lezBusy = true;
        call("lezOpen", [], function (r) {
            if (!r.ok) {
                lezBusy = false;
                fail(r.error);
            }
        });
    }
    function lezFund() {
        lastError = "";
        lezMsg = "";
        lezBusy = true;
        call("lezFund", [], function (r) {
            if (!r.ok) {
                lezBusy = false;
                fail(r.error);
            }
        });
    }
    function lezTransfer(kind, from, to, amt) {
        lastError = "";
        lezMsg = "";
        lezBusy = true;
        call("lezTransfer", [kind, from, to, amt], function (r) {
            if (!r.ok) {
                lezBusy = false;
                fail(r.error);
            }
        });
    }

    // Which transfer method moves funds from a source account to a destination
    // of the given visibility. Source type comes from the picked account; the
    // user names the recipient's type. This hides the shield/deshield jargon.
    function xferKind(srcPublic, destPublic) {
        if (srcPublic && destPublic)
            return "public";       // public → public
        if (srcPublic && !destPublic)
            return "shielded";     // public → private (shield)
        if (!srcPublic && !destPublic)
            return "private";      // private → private
        return "deshielded";                                  // private → public (deshield)
    }
    function fromLabel(a) {
        if (!a)
            return "Select account…";
        return (a.isPublic ? "Public" : "Private") + " · " + shortHex(a.idB58) + " · " + fmt(a.balance) + " tokens";
    }
    // What each base-chain keystore role is. These are the node's protocol
    // keys — only LeaderFunding ("Main") is a general spending account; the
    // rest have specific node jobs and shouldn't normally be spent from.
    function baseRoleInfo(role) {
        switch (role) {
        case "LeaderFunding":
            return {
                name: "Main",
                desc: "Funds block production — your everyday spending account.",
                spendable: true
            };
        case "Stake":
            return {
                name: "Stake",
                desc: "Holds your node's stake. Spending from it can unstake your node.",
                spendable: false
            };
        case "SdpFunding":
            return {
                name: "SDP funding",
                desc: "Funds the node's service-declaration operations.",
                spendable: false
            };
        case "NetworkSwarm":
            return {
                name: "Network",
                desc: "Your node's network identity key.",
                spendable: false
            };
        case "BlendSigning":
            return {
                name: "Blend signing",
                desc: "Signs for the Blend privacy layer.",
                spendable: false
            };
        case "BlendZk":
            return {
                name: "Blend ZK",
                desc: "The Blend privacy layer's zero-knowledge key.",
                spendable: false
            };
        case "VaucherMaster":
            return {
                name: "Voucher master",
                desc: "Master key for the node's vouchers.",
                spendable: false
            };
        default:
            return {
                name: role,
                desc: "A node protocol key — not a general spending account.",
                spendable: false
            };
        }
    }
    // Label for a base-chain account in the sender picker.
    function baseFromLabel(a) {
        if (!a)
            return "Select account…";
        var info = baseRoleInfo(a.role);
        return info.name + (info.spendable ? "" : " · node key") + " · " + shortHex(a.address) + " · " + fmt(a.balance) + " tokens";
    }
    // Index of the Main (LeaderFunding) account — the default sender.
    function baseMainIndex() {
        for (var i = 0; i < baseAccounts.length; i++)
            if (baseAccounts[i].role === "LeaderFunding")
                return i;
        return baseAccounts.length > 0 ? 0 : -1;
    }
    // A private recipient is named by a receiving address (lezpriv1…), which
    // encodes their shielded keys. A public recipient is a plain account id.
    function validRecipient(text, destPublic) {
        var s = (text || "").trim();
        if (!destPublic && s.indexOf("lezpriv1") === 0)
            return true;
        return acctHex(s).length === 64;
    }
    function recipientArg(text, destPublic) {
        var s = (text || "").trim();
        if (!destPublic && s.indexOf("lezpriv1") === 0)
            return s;
        return acctHex(s);
    }
    // Fetch a private account's receiving address and copy it to the clipboard.
    function lezCopyReceive(accountHex) {
        lastError = "";
        call("lezReceiveAddress", [accountHex], function (r) {
            if (r.ok && r.address) {
                copy(r.address, "recv");
                lezMsg = "Receiving address copied — share it with whoever is paying you. Only you will see the money arrive.";
            } else
                fail(r.error || "Could not get the receiving address.");
        });
    }
    function lezBridgeIn(amt) {
        lastError = "";
        lezMsg = "";
        lezBusy = true;
        call("lezBridgeIn", [amt], function (r) {
            if (!r.ok) {
                lezBusy = false;
                fail(r.error);
            }
        });
    }
    function lezClaimVault(amt) {
        lastError = "";
        lezMsg = "";
        lezBusy = true;
        call("lezClaimVault", [amt], function (r) {
            if (!r.ok) {
                lezBusy = false;
                fail(r.error);
            }
        });
    }

    // ── Polling ──────────────────────────────────────────────────────
    function refreshBase() {
        call("nodeStatus", [], function (r) {
            if (!r.ok && r.running === undefined)
                return;
            // A real status reply landed — safe to render the off/welcome view.
            baseStatusKnown = true;
            if (r.httpAddr !== undefined)
                httpAddr = String(r.httpAddr);
            if (r.nodeVersion !== undefined)
                nodeVersion = String(r.nodeVersion);
            if (r.running) {
                _baseMisses = 0;
                if (nodeStatus !== 1)
                    nodeStatus = 3;
                chainMode = String(r.mode || "");
                chainHeight = Number(r.height || 0);
                chainSlot = Number(r.slot || 0);
                peerId = String(r.peerId || "");
                nPeers = Number(r.nPeers);
                nConnections = Number(r.nConnections);
                if (!inscFeedLoaded && !inscFeedLoading)
                    loadInscFeed();
            } else if (nodeStatus === 3) {
                // Don't drop to the welcome screen on one transient miss (a
                // slow probe while the node is fine) — only after a few.
                if (++_baseMisses >= 3) {
                    nodeStatus = 0;
                    chainMode = "";
                }
            } else if (nodeStatus === 1 && !r.setupBusy && !r.running && r.setupError) {
                nodeStatus = 0;
                fail(String(r.setupError));
            }
        });
        if (nodeStatus === 3)
            call("baseAccounts", [], function (r) {
                if (r.ok && Array.isArray(r.accounts)) {
                    // Only reassign when the set actually changed — a fresh
                    // array every poll resets the sender picker's selection.
                    var j = JSON.stringify(r.accounts);
                    if (j !== _baseAccountsJson) {
                        _baseAccountsJson = j;
                        baseAccounts = r.accounts;
                    }
                    baseAccountsLoaded = true;
                }
            });
    }
    function refreshLez() {
        if (lezBusy)
            return;
        call("lezStatus", [], function (r) {
            if (r.error !== undefined && r.ok === false)
                return;
            lezReady = !!r.ready;
            lezHasWallet = !!r.hasWallet;
            lezStatusKnown = true;
            // A persistent wallet already exists → open it silently, no screen.
            if (lezHasWallet && !lezReady && !lezBusy && !lezAutoOpened) {
                lezAutoOpened = true;
                lezOpen();
            }
            // First run — no wallet on disk yet → gate the app behind onboarding.
            if (!lezHasWallet && !lezReady && !lezNeedsRestart && !onbActive)
                onbActive = true;
            lezAccountB58 = String(r.accountB58 || "");
            lezAccountHex = String(r.account || "");
            lezPublicAccountB58 = String(r.publicAccountB58 || "");
            lezPrivateBalance = String(r.privateBalance || "");
            lezPublicBalance = String(r.publicBalance || "");
            lezVault = String(r.vault || "");
            lezLastSynced = Number(r.lastSynced !== undefined ? r.lastSynced : -1);
            lezHeight = Number(r.height !== undefined ? r.height : -1);
        });
        call("lezAccounts", [], function (r) {
            if (r.ok && Array.isArray(r.accounts)) {
                lezAccountsLoaded = true;
                // Only reassign when the set actually changed, so polling doesn't
                // reset the From picker / other bindings while the user is typing.
                var s = JSON.stringify(r.accounts);
                if (s !== root._lezAccountsJson) {
                    root._lezAccountsJson = s;
                    lezAccountsList = r.accounts;
                }
            }
        });
    }

    function lezCreateAccount(kind) {
        lastError = "";
        lezMsg = "";
        lezCreateBusy = true;
        call("lezCreateAccount", [kind], function (r) {
            if (!r.ok) {
                lezCreateBusy = false;
                fail(r.error);
            }
        });
    }

    // Delete the on-disk private wallet (confirmed via the danger dialog).
    function lezReset() {
        lastError = "";
        lezMsg = "";
        call("lezReset", [], function (r) {
            if (!r.ok) {
                fail(r.error);
                return;
            }
            lezReady = false;
            lezHasWallet = false;
            lezAccountsList = [];
            lezAccountsLoaded = false;
            _lezAccountsJson = "";
            lezMnemonic = "";
            lezAutoOpened = true;      // never auto-reopen a deleted wallet
            lezNeedsRestart = !!r.needsRestart;
            if (!r.needsRestart)
                lezMsg = "Wallet deleted.";
            refreshLez();
        });
    }

    // Rebuild the wallet from a recovery phrase → lezRestoreFinished.
    function lezRestoreWallet(mn) {
        lastError = "";
        lezMsg = "";
        lezBusy = true;
        call("lezRestore", [mn], function (r) {
            if (!r.ok) {
                lezBusy = false;
                fail(r.error);
            }
        });
    }

    // ── Sequencer settings ───────────────────────────────────────────
    // Load the current sequencer URL into the dialog fields.
    function loadSeq() {
        call("lezSequencer", [], function (r) {
            if (!r.ok)
                return;
            root.lezSeqUrl = r.url || "";
            root.lezSeqDefault = r.default || "";
            root.lezSeqIsDefault = !!r.isDefault;
            // Fill the dialog on open — but never overwrite what's being typed.
            if (seqOverlay.visible && !seqUrlField.activeFocus)
                seqUrlField.text = root.lezSeqUrl;
        });
    }
    // Persist a new sequencer URL (empty string resets to the built-in default).
    function saveSeq(url) {
        lastError = "";
        lezMsg = "";
        lezSeqBusy = true;
        call("lezSetSequencer", [url.trim()], function (r) {
            lezSeqBusy = false;
            if (!r.ok) {
                fail(r.error);
                return;
            }
            root.lezSeqUrl = r.url || "";
            root.lezSeqIsDefault = !!r.isDefault;
            seqOverlay.visible = false;
            if (r.needsRestart) {
                root.lezMsg = "Sequencer saved. Restart Basecamp to connect through it.";
            } else {
                root.lezMsg = "Sequencer saved.";
                // No wallet open yet → the next open reads the new endpoint,
                // so (re)connect live without a restart.
                if (!root.lezReady && root.lezHasWallet)
                    root.lezOpen();
            }
            root.refreshLez();
        });
    }

    // ── Onboarding helpers ───────────────────────────────────────────
    // Kick off wallet creation; lezOpenFinished advances us to the seed step.
    function onbCreate() {
        onbSaved = false;
        lezOpen();
    }
    // Dev preview: walk the whole flow without creating/restoring anything.
    function onbPreviewStart() {
        onbPreview = true;
        onbSaved = false;
        onbStep = 0;
        onbActive = true;
    }
    function onbPreviewSeed() {
        lezMnemonic = "abandon ability able about above absent absorb abstract absurd abuse access accident account accuse achieve acid acoustic acquire across act action actor actress actual";
        onbSaved = false;
        onbStep = 1;
    }
    // Move from "here's your phrase" to the confirm step, choosing 3 random
    // word positions the user must fill back in.
    function onbToVerify() {
        var words = root.lezMnemonic.trim().split(/\s+/);
        var idx = [];
        while (idx.length < 3 && words.length >= 3) {
            var r = Math.floor(Math.random() * words.length);
            if (idx.indexOf(r) === -1)
                idx.push(r);
        }
        idx.sort(function (a, b) {
            return a - b;
        });
        onbVerifyIdx = idx;
        onbStep = 2;
    }
    function onbVerifyOk(fields) {
        var words = root.lezMnemonic.trim().split(/\s+/);
        for (var i = 0; i < onbVerifyIdx.length; i++)
            if ((fields[i] || "").trim().toLowerCase() !== (words[onbVerifyIdx[i]] || "").toLowerCase())
                return false;
        return true;
    }
    // Finish onboarding: wipe the phrase from memory and drop into the app.
    function onbFinish() {
        lezMnemonic = "";
        onbActive = false;
        onbStep = 0;
        onbSaved = false;
        onbPreview = false;
    }

    Timer {
        interval: 2500
        running: true
        repeat: true
        onTriggered: {
            tick++;
            if (root.tab === 0)
                refreshBase();
            else
                refreshLez();
            if (tick % 3 === 0) {
                refreshBase();
                refreshLez();
            }
        }
    }
    Connections {
        target: (typeof logos !== "undefined") ? logos : null
        function onModuleEventReceived(m, e, d) {
            if (m !== "persona_core")
                return;
            var r;
            try {
                r = JSON.parse(d[0]);
            } catch (x) {
                r = null;
            }
            if (e === "nodeSetupFinished") {
                if (r && r.ok) {
                    nodeStatus = 3;
                    refreshBase();
                } else {
                    nodeStatus = 0;
                    fail(r ? r.error : "Node setup failed.");
                }
            } else if (e === "inscribeFinished") {
                inscribeBusy = false;
                if (r && r.ok) {
                    lastInscribe = "Inscribed on the chain forever ✓ " + (r.tip ? shortHex(String(r.tip)) : "");
                    inscribeField.text = "";
                    loadInscFeed();
                } else
                    fail(r ? r.error : "The inscription failed.");
            } else if (e === "recentInscriptionsFinished") {
                inscFeedLoading = false;
                inscFeedLoaded = true;
                if (r && r.ok && Array.isArray(r.inscriptions))
                    inscFeed = r.inscriptions;
            } else if (e === "recentBlocksFinished") {
                blocksLoading = false;
                if (r && r.ok && Array.isArray(r.blocks))
                    recentBlocksList = r.blocks;
            } else if (e === "lezOpenFinished") {
                lezBusy = false;
                if (r && r.ok) {
                    lezReady = true;
                    lezAccountB58 = String(r.accountB58 || "");
                    if (r.mnemonic && r.mnemonic.length)
                        lezMnemonic = String(r.mnemonic);
                    // Freshly created during onboarding → show the phrase.
                    if (onbActive && r.mnemonic && r.mnemonic.length)
                        onbStep = 1;
                    refreshLez();
                } else
                    fail(r ? r.error : "Could not open your private wallet.");
            } else if (e === "lezFundFinished") {
                lezBusy = false;
                if (r && r.ok) {
                    lezMsg = r.shielded ? ("Added " + (r.prize || 150) + " free tokens to your private balance ✓") : ("Got " + (r.prize || 150) + " free tokens (public for now — shielding to private will retry). " + (r.note || ""));
                    refreshLez();
                } else
                    fail(r ? r.error : "Could not get tokens from the faucet.");
            } else if (e === "lezTransferFinished") {
                lezBusy = false;
                if (r && r.ok) {
                    lezMsg = "Transfer sent ✓";
                    refreshLez();
                } else
                    fail(r ? r.error : "The transfer did not go through.");
            } else if (e === "lezAccountCreated") {
                lezCreateBusy = false;
                var rr;
                try {
                    rr = JSON.parse(d[0]);
                } catch (x) {
                    rr = null;
                }
                if (rr && rr.ok) {
                    lezMsg = "New " + (rr.isPublic ? "public" : "private") + " account is ready ✓";
                    refreshLez();
                } else
                    fail(rr ? rr.error : "Could not create the account.");
            } else if (e === "lezBridgeFinished") {
                lezBusy = false;
                if (r && r.ok) {
                    lezMsg = (r.kind === "deposit") ? ("Tokens are on their way from the base chain — they reach your vault in about an hour. (receipt " + shortHex(String(r.tx || "")) + ")") : "Claimed into your private balance ✓";
                    refreshLez();
                } else
                    fail(r ? r.error : "The bridge transfer failed.");
            } else if (e === "lezRestoreFinished") {
                lezBusy = false;
                if (r && r.ok) {
                    lezReady = true;
                    lezHasWallet = true;
                    lezNeedsRestart = false;
                    lezMsg = "Wallet restored ✓ — balances reappear as it re-syncs.";
                    // Imported during onboarding → drop straight into the app.
                    if (onbActive)
                        onbFinish();
                    refreshLez();
                } else
                    fail(r ? r.error : "The restore failed.");
            }
        }
    }
    Component.onCompleted: {
        if (typeof logos !== "undefined" && logos.onModuleEvent) {
            var evs = ["nodeSetupFinished", "inscribeFinished", "recentInscriptionsFinished", "recentBlocksFinished", "lezOpenFinished", "lezAccountCreated", "lezFundFinished", "lezTransferFinished", "lezBridgeFinished", "lezRestoreFinished"];
            for (var i = 0; i < evs.length; i++)
                logos.onModuleEvent("persona_core", evs[i]);
        }
        refreshBase();
        refreshLez();
        loadSeq();
    }

    // ── Display helpers ──────────────────────────────────────────────
    function shortHex(h) {
        return h.length > 20 ? h.substring(0, 10) + "…" + h.substring(h.length - 8) : h;
    }
    function fmt(n) {
        return (Number(n) < 0) ? "…" : Number(n).toLocaleString(Qt.locale(), 'f', 0);
    }
    TextEdit {
        id: clip
        visible: false
    }
    function copy(t, label) {
        clip.text = t;
        clip.selectAll();
        clip.copy();
        copied = label;
        copyTimer.restart();
    }
    Timer {
        id: copyTimer
        interval: 1500
        onTriggered: root.copied = ""
    }

    // Shared numeric validator, attached to amount fields via textInput.
    RegularExpressionValidator {
        id: intValidator
        regularExpression: /[0-9]*/
    }

    // Brand coral gradient (same ramp as the plugin icon tile).
    Gradient {
        id: accentGrad
        GradientStop {
            position: 0.0
            color: "#F28E6B"
        }
        GradientStop {
            position: 1.0
            color: "#E1613A"
        }
    }

    // ── Design-system building blocks ────────────────────────────────

    // Neutral charcoal card with an optional coral-ticked micro-title.
    // glow: true adds a faint coral wash + floating orbs (hero cards).
    component Card: Rectangle {
        id: cardRoot
        default property alias content: cardCol.data
        property string title: ""
        property string tip: ""
        property bool glow: false
        Layout.fillWidth: true
        color: Theme.palette.backgroundTertiary
        border.color: Theme.palette.borderSubtle
        border.width: 1
        radius: Theme.spacing.radiusLarge
        implicitHeight: cardCol.implicitHeight + Theme.spacing.large * 2

        // Faint coral wash falling from the top edge.
        Rectangle {
            visible: cardRoot.glow
            anchors.fill: parent
            radius: cardRoot.radius
            gradient: Gradient {
                GradientStop {
                    position: 0.0
                    color: Theme.colors.getColor(Theme.palette.primary, 0.10)
                }
                GradientStop {
                    position: 0.6
                    color: "transparent"
                }
            }
        }
        // Floating orbs echoing the circular Logos mark.
        Rectangle {
            visible: cardRoot.glow
            width: 120
            height: 120
            radius: 60
            anchors {
                top: parent.top
                right: parent.right
                topMargin: 14
                rightMargin: 22
            }
            color: "transparent"
            border.width: 1.5
            border.color: Theme.colors.getColor(Theme.palette.primary, 0.25)
        }
        Rectangle {
            visible: cardRoot.glow
            width: 52
            height: 52
            radius: 26
            anchors {
                top: parent.top
                right: parent.right
                topMargin: 52
                rightMargin: 120
            }
            color: Theme.colors.getColor(Theme.palette.primary, 0.10)
        }

        ColumnLayout {
            id: cardCol
            anchors {
                fill: parent
                margins: Theme.spacing.large
            }
            spacing: Theme.spacing.medium
            RowLayout {
                visible: cardRoot.title.length > 0
                spacing: Theme.spacing.small
                Rectangle {
                    implicitWidth: 4
                    implicitHeight: 12
                    radius: 2
                    color: Theme.palette.primary
                }
                LogosText {
                    text: cardRoot.title
                    color: Theme.palette.textSecondary
                    font.pixelSize: 11
                    font.weight: Theme.typography.weightMedium
                    font.letterSpacing: 0.8
                    font.capitalization: Font.AllUppercase
                }
                InfoTip {
                    tip: cardRoot.tip
                }
            }
        }
    }

    // Auto-sizing button in the Basecamp idiom; accent = coral-tinted CTA.
    component ActionButton: Control {
        id: btn
        property string text: ""
        property string tip: ""
        property bool accent: false
        property bool danger: false
        signal clicked
        hoverEnabled: true
        implicitHeight: 36
        implicitWidth: btnLabel.implicitWidth + 32
        readonly property bool isActive: btnMa.pressed || btn.hovered
        // springy press feedback
        scale: (btnMa.pressed && btn.enabled) ? 0.96 : 1.0
        Behavior on scale {
            NumberAnimation {
                duration: 90
                easing.type: Easing.OutQuad
            }
        }
        Tip {
            text: btn.tip
            visible: btn.hovered && btn.tip.length > 0
        }
        background: Rectangle {
            radius: Theme.spacing.radiusXlarge
            gradient: (btn.accent && btn.enabled) ? accentGrad : null
            color: !btn.enabled ? Theme.palette.backgroundMuted : btn.danger ? Theme.colors.getColor(Theme.palette.error, btn.isActive ? 0.30 : 0.15) : (btn.isActive ? Theme.palette.backgroundMuted : Theme.palette.backgroundSecondary)
            border.width: (btn.accent && btn.enabled) ? 0 : 1
            border.color: !btn.enabled ? Theme.palette.border : btn.danger ? Theme.palette.error : (btn.isActive ? Theme.palette.overlayOrange : Theme.palette.border)
            Behavior on color {
                ColorAnimation {
                    duration: 120
                }
            }
            Behavior on border.color {
                ColorAnimation {
                    duration: 120
                }
            }
            // hover/press shine on the filled coral variant
            Rectangle {
                anchors.fill: parent
                radius: parent.radius
                color: "#FFFFFF"
                opacity: (btn.accent && btn.enabled && btn.isActive) ? 0.14 : 0
                Behavior on opacity {
                    NumberAnimation {
                        duration: 120
                    }
                }
            }
        }
        contentItem: LogosText {
            id: btnLabel
            text: btn.text
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
            font.pixelSize: Theme.typography.secondaryText
            font.weight: btn.accent ? Theme.typography.weightBold : Theme.typography.weightMedium
            color: !btn.enabled ? Theme.palette.textMuted : btn.accent ? "#241511" : btn.danger ? Theme.palette.error : Theme.palette.text
        }
        MouseArea {
            id: btnMa
            anchors.fill: parent
            enabled: btn.enabled
            cursorShape: btn.enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
            onClicked: btn.clicked()
        }
    }

    // Small pill ghost-button for inline actions (copy, receive, links).
    component MiniButton: Control {
        id: mb
        property string label: ""
        property string tip: ""
        signal clicked
        hoverEnabled: true
        implicitHeight: 26
        implicitWidth: mbLabel.implicitWidth + 20
        scale: mbMa.pressed ? 0.94 : 1.0
        Behavior on scale {
            NumberAnimation {
                duration: 90
                easing.type: Easing.OutQuad
            }
        }
        Tip {
            text: mb.tip
            visible: mb.hovered && mb.tip.length > 0
        }
        background: Rectangle {
            radius: Theme.spacing.radiusPill
            color: mb.hovered ? Theme.palette.backgroundMuted : "transparent"
            border.width: 1
            border.color: mb.hovered ? Theme.palette.overlayOrange : Theme.palette.borderSubtle
            Behavior on color {
                ColorAnimation {
                    duration: 120
                }
            }
            Behavior on border.color {
                ColorAnimation {
                    duration: 120
                }
            }
        }
        contentItem: LogosText {
            id: mbLabel
            text: mb.label
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
            font.pixelSize: 11
            font.weight: Theme.typography.weightMedium
            color: mb.hovered ? Theme.palette.text : Theme.palette.textSecondary
            Behavior on color {
                ColorAnimation {
                    duration: 120
                }
            }
        }
        MouseArea {
            id: mbMa
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: mb.clicked()
        }
    }

    // Status dot with a soft halo; pulses while something is in flight.
    component StatusDot: Item {
        id: sdot
        property color c: Theme.palette.textTertiary
        property bool pulsing: false
        implicitWidth: 16
        implicitHeight: 16
        onPulsingChanged: if (!pulsing)
            halo.opacity = 1
        Rectangle {
            id: halo
            anchors.fill: parent
            radius: width / 2
            color: Theme.colors.getColor(sdot.c, 0.22)
            SequentialAnimation on opacity {
                running: sdot.pulsing
                loops: Animation.Infinite
                NumberAnimation {
                    from: 1
                    to: 0.25
                    duration: 700
                    easing.type: Easing.InOutQuad
                }
                NumberAnimation {
                    from: 0.25
                    to: 1
                    duration: 700
                    easing.type: Easing.InOutQuad
                }
            }
        }
        Rectangle {
            anchors.centerIn: parent
            width: 8
            height: 8
            radius: 4
            color: sdot.c
        }
    }

    // Monospace text for addresses, hashes and mnemonics.
    component Mono: LogosText {
        font.family: "Menlo"
        font.pixelSize: Theme.typography.secondaryText
        color: Theme.palette.text
    }

    component Hairline: Rectangle {
        Layout.fillWidth: true
        implicitHeight: 1
        color: Theme.palette.borderHairline
    }

    // Inset stat tile for the technical-details section.
    component StatTile: Rectangle {
        id: stile
        property string label: ""
        property string value: ""
        Layout.fillWidth: true
        implicitHeight: 58
        radius: Theme.spacing.radiusMedium
        color: Theme.palette.backgroundInset
        border.width: 1
        border.color: Theme.palette.borderHairline
        ColumnLayout {
            anchors {
                left: parent.left
                right: parent.right
                verticalCenter: parent.verticalCenter
                leftMargin: Theme.spacing.medium
                rightMargin: Theme.spacing.medium
            }
            spacing: 3
            LogosText {
                text: stile.label
                color: Theme.palette.textTertiary
                font.pixelSize: 10
                font.weight: Theme.typography.weightMedium
                font.letterSpacing: 0.8
                font.capitalization: Font.AllUppercase
            }
            LogosText {
                Layout.fillWidth: true
                text: stile.value
                color: Theme.palette.text
                font.family: "Menlo"
                font.pixelSize: Theme.typography.primaryText
                elide: Text.ElideRight
            }
        }
    }

    // Label ▸ value row for the node-info sheet; copyKey adds a Copy button.
    component InfoRow: RowLayout {
        property string k: ""
        property string v: ""
        property string copyKey: ""
        Layout.fillWidth: true
        spacing: Theme.spacing.medium
        LogosText {
            Layout.preferredWidth: 118
            text: k
            color: Theme.palette.textTertiary
            font.pixelSize: 10
            font.weight: Theme.typography.weightMedium
            font.letterSpacing: 0.8
            font.capitalization: Font.AllUppercase
        }
        Mono {
            Layout.fillWidth: true
            text: v.length ? v : "—"
            horizontalAlignment: Text.AlignRight
            elide: Text.ElideRight
        }
        MiniButton {
            visible: copyKey.length > 0
            label: root.copied === copyKey ? "✓ Copied" : "Copy"
            onClicked: root.copy(v, copyKey)
        }
    }

    // Fixed-width form label so all input rows align.
    component FormLabel: LogosText {
        Layout.preferredWidth: 64
        color: Theme.palette.textSecondary
        font.pixelSize: Theme.typography.secondaryText
    }

    // LogosToolTip tuned for multi-line hints: wraps at ~320px, no timeout.
    component Tip: LogosToolTip {
        id: tipRoot
        timeout: -1
        delay: 150
        placement: LogosToolTip.Top
        width: Math.min(implicitWidth, 320)
        height: labelItem.implicitHeight + verticalPadding * 2 + 4
        horizontalPadding: Theme.spacing.small
        verticalPadding: Theme.spacing.tiny
        Component.onCompleted: labelItem.wrapMode = Text.Wrap
    }

    // Tiny circled "i" that reveals a tooltip on hover.
    component InfoTip: Item {
        id: itip
        property string tip: ""
        implicitWidth: 16
        implicitHeight: 16
        visible: tip.length > 0
        HoverHandler {
            id: itipHover
        }
        Rectangle {
            anchors.fill: parent
            radius: 8
            color: itipHover.hovered ? Theme.colors.getColor(Theme.palette.primary, 0.16) : "transparent"
            border.width: 1
            border.color: itipHover.hovered ? Theme.palette.primary : Theme.palette.borderStrong
            Behavior on border.color {
                ColorAnimation {
                    duration: 120
                }
            }
            LogosText {
                anchors.centerIn: parent
                text: "i"
                font.pixelSize: 10
                font.weight: Theme.typography.weightBold
                color: itipHover.hovered ? Theme.palette.primary : Theme.palette.textTertiary
            }
        }
        Tip {
            text: itip.tip
            visible: itipHover.hovered
        }
    }

    // Small tinted capsule chip (e.g. "1,250 private").
    component Chip: Rectangle {
        id: chip
        property string label: ""
        property color tint: Theme.palette.primary
        radius: Theme.spacing.radiusPill
        color: Theme.colors.getColor(chip.tint, 0.13)
        border.width: 1
        border.color: Theme.colors.getColor(chip.tint, 0.45)
        implicitHeight: 24
        implicitWidth: chipLabel.implicitWidth + 20
        LogosText {
            id: chipLabel
            anchors.centerIn: parent
            text: chip.label
            font.pixelSize: 11
            font.weight: Theme.typography.weightMedium
            color: chip.tint
        }
    }

    // Status capsule — halo dot + label in an inset pill.
    component StatusPill: Rectangle {
        id: spill
        property color c: Theme.palette.success
        property bool pulsing: false
        property string label: ""
        property string tip: ""
        HoverHandler {
            id: spillHover
        }
        Tip {
            text: spill.tip
            visible: spillHover.hovered && spill.tip.length > 0
        }
        radius: Theme.spacing.radiusPill
        color: Theme.palette.backgroundInset
        border.width: 1
        border.color: Theme.palette.borderHairline
        implicitHeight: 30
        implicitWidth: spillRow.implicitWidth + 24
        RowLayout {
            id: spillRow
            anchors.centerIn: parent
            spacing: 6
            StatusDot {
                c: spill.c
                pulsing: spill.pulsing
            }
            LogosText {
                text: spill.label
                font.pixelSize: Theme.typography.secondaryText
                font.weight: Theme.typography.weightMedium
                color: Theme.palette.text
            }
        }
    }

    // Round identicon-ish avatar for account rows: tinted circle + id prefix.
    component AccountAvatar: Item {
        // Deterministic blockies-style identicon seeded by the account's
        // public key / address — same visual identity everywhere, no network.
        id: avat
        property string seed: ""
        implicitWidth: 28
        implicitHeight: 28
        onSeedChanged: avatCanvas.requestPaint()
        Canvas {
            id: avatCanvas
            anchors.fill: parent
            onPaint: {
                var c = getContext("2d");
                c.reset();
                var cellsAcross = 8;
                var scale = width / cellsAcross;
                // xorshift PRNG seeded from the key (the blockies scheme)
                var rs = [0, 0, 0, 0];
                var s = avat.seed;
                for (var i = 0; i < s.length; i++)
                    rs[i % 4] = ((rs[i % 4] << 5) - rs[i % 4]) + s.charCodeAt(i);
                function rnd() {
                    var t = rs[0] ^ (rs[0] << 11);
                    rs[0] = rs[1];
                    rs[1] = rs[2];
                    rs[2] = rs[3];
                    rs[3] = (rs[3] ^ (rs[3] >> 19) ^ t ^ (t >> 8));
                    return ((rs[3] >>> 0) / ((1 << 31) >>> 0));
                }
                function col() {
                    // lightness clamped to 0.3–0.8 so icons stay legible on
                    // the dark theme
                    var h = rnd();
                    var sat = 0.4 + rnd() * 0.6;
                    var lig = 0.3 + (rnd() + rnd()) * 0.25;
                    return Qt.hsla(h, sat, lig, 1);
                }
                var main = col(), bg = col(), spot = col();
                // vertically-mirrored pattern: 0 = bg, 1 = main, 2 = spot
                var half = cellsAcross / 2;
                var rows = [];
                for (var y = 0; y < cellsAcross; y++) {
                    var row = [];
                    for (var x = 0; x < half; x++)
                        row.push(Math.floor(rnd() * 2.3));
                    rows.push(row.concat(row.slice().reverse()));
                }
                c.beginPath();
                c.arc(width / 2, height / 2, width / 2, 0, Math.PI * 2);
                c.clip();
                c.fillStyle = bg;
                c.fillRect(0, 0, width, height);
                for (var yy = 0; yy < cellsAcross; yy++) {
                    for (var xx = 0; xx < cellsAcross; xx++) {
                        var v = rows[yy][xx];
                        if (v > 0) {
                            c.fillStyle = (v === 1) ? main : spot;
                            c.fillRect(xx * scale, yy * scale, scale + 0.5, scale + 0.5);
                        }
                    }
                }
            }
        }
        // hairline ring so the icon sits cleanly on any row surface
        Rectangle {
            anchors.fill: parent
            radius: width / 2
            color: "transparent"
            border.width: 1
            border.color: Theme.palette.borderHairline
        }
    }

    // Pulsing placeholder row shown while an account list is still loading.
    component SkeletonRow: Rectangle {
        Layout.fillWidth: true
        implicitHeight: 48
        radius: Theme.spacing.radiusLarge
        color: Theme.palette.backgroundSecondary
        SequentialAnimation on opacity {
            loops: Animation.Infinite
            running: visible
            NumberAnimation {
                from: 0.9
                to: 0.4
                duration: 600
                easing.type: Easing.InOutQuad
            }
            NumberAnimation {
                from: 0.4
                to: 0.9
                duration: 600
                easing.type: Easing.InOutQuad
            }
        }
        RowLayout {
            anchors {
                left: parent.left
                right: parent.right
                verticalCenter: parent.verticalCenter
                leftMargin: Theme.spacing.medium
                rightMargin: Theme.spacing.medium
            }
            spacing: Theme.spacing.small
            Rectangle {
                implicitWidth: 28
                implicitHeight: 28
                radius: 14
                color: Theme.palette.backgroundButton
            }
            Rectangle {
                implicitWidth: 180
                implicitHeight: 10
                radius: 5
                color: Theme.palette.backgroundButton
            }
            Item {
                Layout.fillWidth: true
            }
            Rectangle {
                implicitWidth: 56
                implicitHeight: 12
                radius: 6
                color: Theme.palette.backgroundButton
            }
        }
    }

    // Big-number + caption block for the overview cards.
    component HeroBalance: ColumnLayout {
        id: hero
        property string caption: ""
        property string value: ""
        property string sub: ""
        property string tip: ""
        spacing: 2
        RowLayout {
            spacing: Theme.spacing.tiny
            LogosText {
                text: hero.caption
                color: Theme.palette.textTertiary
                font.pixelSize: 11
                font.weight: Theme.typography.weightMedium
                font.letterSpacing: 0.8
                font.capitalization: Font.AllUppercase
            }
            InfoTip {
                tip: hero.tip
            }
        }
        LogosText {
            text: hero.value
            color: Theme.palette.text
            font.pixelSize: 42
            font.weight: Theme.typography.weightBold
        }
        LogosText {
            visible: hero.sub.length > 0
            text: hero.sub
            color: Theme.palette.textTertiary
            font.pixelSize: 11
        }
    }

    // Numbered step tile for the "how it works" walkthrough — lays out 3-up
    // on wide viewports, stacked when narrow.
    component StepTile: Rectangle {
        id: stept
        property int num: 1
        property string text: ""
        Layout.fillWidth: true
        Layout.fillHeight: true
        Layout.preferredWidth: 100
        radius: Theme.spacing.radiusMedium
        color: Theme.palette.backgroundInset
        border.width: 1
        border.color: Theme.palette.borderHairline
        implicitHeight: steptCol.implicitHeight + Theme.spacing.large * 2
        ColumnLayout {
            id: steptCol
            anchors {
                left: parent.left
                right: parent.right
                top: parent.top
                margins: Theme.spacing.large
            }
            spacing: Theme.spacing.small
            Rectangle {
                implicitWidth: 28
                implicitHeight: 28
                radius: 14
                color: Theme.colors.getColor(Theme.palette.primary, 0.16)
                border.color: Theme.palette.primary
                border.width: 1
                LogosText {
                    anchors.centerIn: parent
                    text: stept.num
                    color: Theme.palette.primary
                    font.pixelSize: Theme.typography.secondaryText
                    font.weight: Theme.typography.weightBold
                }
            }
            LogosText {
                Layout.fillWidth: true
                text: stept.text
                wrapMode: Text.Wrap
                color: Theme.palette.textSecondary
                font.pixelSize: Theme.typography.secondaryText
            }
        }
    }

    // Tinted, plain-language notice (e.g. "who can see this transfer?").
    component NoticeBanner: Rectangle {
        id: nb
        property color tint: Theme.palette.info
        property string text: ""
        Layout.fillWidth: true
        color: Theme.colors.getColor(nb.tint, 0.10)
        border.color: Theme.colors.getColor(nb.tint, 0.40)
        border.width: 1
        radius: Theme.spacing.radiusMedium
        implicitHeight: nbText.implicitHeight + Theme.spacing.medium * 2
        LogosText {
            id: nbText
            anchors {
                left: parent.left
                right: parent.right
                verticalCenter: parent.verticalCenter
                leftMargin: Theme.spacing.medium
                rightMargin: Theme.spacing.medium
            }
            text: nb.text
            wrapMode: Text.Wrap
            color: Theme.palette.text
            font.pixelSize: Theme.typography.secondaryText
        }
    }

    // ── Layout ───────────────────────────────────────────────────────
    ColumnLayout {
        anchors {
            top: parent.top
            bottom: parent.bottom
            topMargin: Theme.spacing.xlarge
            bottomMargin: Theme.spacing.xlarge
            horizontalCenter: parent.horizontalCenter
        }
        width: Math.min(root.width - Theme.spacing.xlarge * 2, 1240)
        spacing: Theme.spacing.large

        // Tabs — plugin logo + full-width bar with the sliding coral indicator
        RowLayout {
            Layout.fillWidth: true
            spacing: Theme.spacing.medium
            Image {
                source: "icons/logos-wallet.png"
                Layout.preferredWidth: 32
                Layout.preferredHeight: 32
                sourceSize: Qt.size(128, 128)
                smooth: true
            }
            LogosText {
                text: "Persona"
                color: Theme.palette.text
                font.pixelSize: Theme.typography.subtitleText
                font.weight: Theme.typography.weightBold
                Layout.rightMargin: Theme.spacing.small
            }
            LogosTabBar {
                id: tabBar
                Layout.fillWidth: true
                currentIndex: root.tab
                onCurrentIndexChanged: root.tab = currentIndex
                LogosTabButton {
                    text: "Base chain"
                }
                LogosTabButton {
                    text: "LEZ (Zone)"
                }
            }
            // TEMP: preview the first-run onboarding without touching the wallet.
            MiniButton {
                label: "Preview onboarding"
                tip: "Walk through the first-run setup flow (nothing is created or changed)."
                onClicked: root.onbPreviewStart()
            }
        }

        // Error banner
        Rectangle {
            Layout.fillWidth: true
            visible: root.lastError.length > 0
            color: Theme.colors.getColor(Theme.palette.error, 0.10)
            border.color: Theme.colors.getColor(Theme.palette.error, 0.45)
            border.width: 1
            radius: Theme.spacing.radiusLarge
            implicitHeight: errRow.implicitHeight + Theme.spacing.medium * 2
            RowLayout {
                id: errRow
                anchors {
                    left: parent.left
                    right: parent.right
                    verticalCenter: parent.verticalCenter
                    margins: Theme.spacing.medium
                }
                spacing: Theme.spacing.small
                LogosText {
                    Layout.fillWidth: true
                    text: "Something went wrong: " + root.lastError
                    wrapMode: Text.Wrap
                    color: Theme.palette.error
                    font.pixelSize: Theme.typography.secondaryText
                }
                MiniButton {
                    label: "Dismiss"
                    onClicked: root.lastError = ""
                }
            }
        }

        // Body fills the viewport — no page-level scrollbar. Sections that
        // can outgrow their frame (the account lists) scroll internally.
        Loader {
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            sourceComponent: root.tab === 0 ? bedrockTab : lezTab
        }
    }

    // ── Danger dialog: delete the private wallet ─────────────────────
    Rectangle {
        id: resetOverlay
        function open() {
            resetConfirmField.text = "";
            visible = true;
        }
        visible: false
        anchors.fill: parent
        z: 100
        color: Qt.rgba(0, 0, 0, 0.62)
        // swallow clicks behind the dialog
        MouseArea {
            anchors.fill: parent
            hoverEnabled: true
        }
        Card {
            anchors.centerIn: parent
            width: Math.min(parent.width - Theme.spacing.xxlarge * 2, 470)
            opacity: resetOverlay.visible ? 1 : 0
            scale: resetOverlay.visible ? 1 : 0.95
            Behavior on opacity {
                NumberAnimation {
                    duration: 170
                    easing.type: Easing.OutCubic
                }
            }
            Behavior on scale {
                NumberAnimation {
                    duration: 200
                    easing.type: Easing.OutCubic
                }
            }
            title: "Delete private wallet"
            LogosText {
                Layout.fillWidth: true
                wrapMode: Text.Wrap
                color: Theme.palette.textSecondary
                font.pixelSize: Theme.typography.primaryText
                text: "This permanently deletes the private wallet and all its accounts from this computer. The only way back is a restore with the recovery phrase — without it, any balance is gone for good."
            }
            LogosText {
                text: "Type DELETE to confirm:"
                color: Theme.palette.textSecondary
                font.pixelSize: Theme.typography.secondaryText
            }
            LogosTextField {
                id: resetConfirmField
                Layout.fillWidth: true
                placeholderText: "DELETE"
                enabled: !root.lezBusy
            }
            RowLayout {
                Layout.fillWidth: true
                ActionButton {
                    text: "Cancel"
                    onClicked: resetOverlay.visible = false
                }
                Item {
                    Layout.fillWidth: true
                }
                ActionButton {
                    danger: true
                    text: "Delete wallet"
                    enabled: resetConfirmField.text.trim() === "DELETE" && !root.lezBusy
                    onClicked: {
                        resetOverlay.visible = false;
                        root.lezReset();
                    }
                }
            }
        }
    }

    // ── Sequencer settings dialog ────────────────────────────────────
    Rectangle {
        id: seqOverlay
        objectName: "seqOverlay"
        function open() {
            seqUrlField.text = root.lezSeqUrl;
            root.loadSeq();
            visible = true;
        }
        visible: false
        anchors.fill: parent
        z: 100
        color: Qt.rgba(0, 0, 0, 0.62)
        MouseArea {
            anchors.fill: parent
            hoverEnabled: true
            onClicked: seqOverlay.visible = false
        }
        Card {
            anchors.centerIn: parent
            width: Math.min(parent.width - Theme.spacing.xxlarge * 2, 520)
            opacity: seqOverlay.visible ? 1 : 0
            scale: seqOverlay.visible ? 1 : 0.95
            Behavior on opacity {
                NumberAnimation {
                    duration: 170
                    easing.type: Easing.OutCubic
                }
            }
            Behavior on scale {
                NumberAnimation {
                    duration: 200
                    easing.type: Easing.OutCubic
                }
            }
            // keep clicks inside the card from dismissing the dialog
            MouseArea {
                anchors.fill: parent
                onClicked: {}
            }
            title: "LEZ sequencer"
            LogosText {
                Layout.fillWidth: true
                wrapMode: Text.Wrap
                color: Theme.palette.textSecondary
                font.pixelSize: Theme.typography.primaryText
                text: "The private wallet connects to this sequencer to sync, read balances and submit transactions. Change it to route around a testnet outage or to use your own sequencer."
            }
            LogosText {
                text: "Sequencer URL"
                color: Theme.palette.textSecondary
                font.pixelSize: Theme.typography.secondaryText
            }
            LogosTextField {
                id: seqUrlField
                Layout.fillWidth: true
                placeholderText: root.lezSeqDefault.length ? root.lezSeqDefault : "https://…"
                enabled: !root.lezSeqBusy
            }
            LogosText {
                Layout.fillWidth: true
                wrapMode: Text.Wrap
                visible: root.lezReady
                color: Theme.palette.warning
                font.pixelSize: Theme.typography.secondaryText
                text: "A wallet is already connected — Basecamp must restart for a new sequencer to take effect."
            }
            RowLayout {
                Layout.fillWidth: true
                spacing: Theme.spacing.small
                MiniButton {
                    label: "Reset to default"
                    enabled: !root.lezSeqBusy && !root.lezSeqIsDefault
                    tip: root.lezSeqDefault
                    onClicked: root.saveSeq("")
                }
                Item {
                    Layout.fillWidth: true
                }
                ActionButton {
                    text: "Cancel"
                    enabled: !root.lezSeqBusy
                    onClicked: seqOverlay.visible = false
                }
                ActionButton {
                    accent: true
                    text: root.lezSeqBusy ? "Saving…" : "Save"
                    enabled: !root.lezSeqBusy && seqUrlField.text.trim().length > 0 && seqUrlField.text.trim() !== root.lezSeqUrl
                    onClicked: root.saveSeq(seqUrlField.text)
                }
            }
        }
    }

    // ── Node info sheet ──────────────────────────────────────────────
    Rectangle {
        id: nodeInfoOverlay
        objectName: "nodeInfoOverlay"
        function open() {
            visible = true;
        }
        visible: false
        anchors.fill: parent
        z: 100
        color: Qt.rgba(0, 0, 0, 0.62)
        // swallow clicks behind the dialog
        MouseArea {
            anchors.fill: parent
            hoverEnabled: true
        }
        Card {
            anchors.centerIn: parent
            width: Math.min(parent.width - Theme.spacing.xxlarge * 2, 480)
            opacity: nodeInfoOverlay.visible ? 1 : 0
            scale: nodeInfoOverlay.visible ? 1 : 0.95
            Behavior on opacity {
                NumberAnimation {
                    duration: 170
                    easing.type: Easing.OutCubic
                }
            }
            Behavior on scale {
                NumberAnimation {
                    duration: 200
                    easing.type: Easing.OutCubic
                }
            }
            title: "Node info"
            tip: "Live configuration and status of your base-chain node."
            InfoRow {
                k: "Status"
                v: root.chainMode === "Online" ? "Online" : (root.chainMode.length ? "Syncing (" + root.chainMode + ")" : "Starting…")
            }
            InfoRow {
                k: "Node version"
                v: root.nodeVersion
            }
            InfoRow {
                k: "HTTP API"
                v: root.httpAddr
                copyKey: "nodeHttp"
            }
            InfoRow {
                k: "Data folder"
                v: "~/.logos-wallet"
                copyKey: "nodeDir"
            }
            Hairline {}
            InfoRow {
                k: "Block height"
                v: root.fmt(root.chainHeight)
            }
            InfoRow {
                k: "Slot"
                v: root.fmt(root.chainSlot)
            }
            InfoRow {
                k: "Peers"
                v: root.nPeers >= 0 ? String(root.nPeers) : "—"
            }
            InfoRow {
                k: "Connections"
                v: root.nConnections >= 0 ? String(root.nConnections) : "—"
            }
            Hairline {}
            LogosText {
                text: "PEER ID"
                color: Theme.palette.textTertiary
                font.pixelSize: 10
                font.weight: Theme.typography.weightMedium
                font.letterSpacing: 0.8
                font.capitalization: Font.AllUppercase
            }
            RowLayout {
                Layout.fillWidth: true
                spacing: Theme.spacing.medium
                Mono {
                    Layout.fillWidth: true
                    text: root.peerId.length ? root.peerId : "—"
                    wrapMode: Text.WrapAnywhere
                    font.pixelSize: 11
                    color: Theme.palette.textSecondary
                }
                MiniButton {
                    visible: root.peerId.length > 0
                    label: root.copied === "nodePeer" ? "✓ Copied" : "Copy"
                    onClicked: root.copy(root.peerId, "nodePeer")
                }
            }
            RowLayout {
                Layout.fillWidth: true
                Item {
                    Layout.fillWidth: true
                }
                ActionButton {
                    text: "Close"
                    onClicked: nodeInfoOverlay.visible = false
                }
            }
        }
    }

    // ── Recent blocks sheet ──────────────────────────────────────────
    Rectangle {
        id: blocksOverlay
        objectName: "blocksOverlay"
        function open() {
            visible = true;
        }
        visible: false
        anchors.fill: parent
        z: 100
        color: Qt.rgba(0, 0, 0, 0.62)
        MouseArea {
            anchors.fill: parent
            hoverEnabled: true
        }
        Card {
            anchors.centerIn: parent
            width: Math.min(parent.width - Theme.spacing.xxlarge * 2, 500)
            opacity: blocksOverlay.visible ? 1 : 0
            scale: blocksOverlay.visible ? 1 : 0.95
            Behavior on opacity {
                NumberAnimation {
                    duration: 170
                    easing.type: Easing.OutCubic
                }
            }
            Behavior on scale {
                NumberAnimation {
                    duration: 200
                    easing.type: Easing.OutCubic
                }
            }
            title: "Recent blocks"
            tip: "The latest blocks on the base chain, newest first — height, slot, block hash and how many transactions each carries."
            RowLayout {
                Layout.fillWidth: true
                spacing: Theme.spacing.small
                LogosText {
                    Layout.fillWidth: true
                    text: root.chainMode === "Online" ? "Chain tip #" + root.fmt(root.chainHeight) : "Syncing…"
                    color: Theme.palette.textSecondary
                    font.pixelSize: Theme.typography.secondaryText
                }
                MiniButton {
                    label: root.blocksLoading ? "Loading…" : "Refresh"
                    tip: "Re-read the latest blocks from your node."
                    onClicked: root.loadRecentBlocks()
                }
            }
            ColumnLayout {
                visible: root.blocksLoading && root.recentBlocksList.length === 0
                Layout.fillWidth: true
                spacing: Theme.spacing.small
                SkeletonRow {}
                SkeletonRow {}
                SkeletonRow {}
            }
            ListView {
                id: blocksList
                add: Transition {
                    NumberAnimation {
                        property: "opacity"
                        from: 0
                        to: 1
                        duration: 220
                        easing.type: Easing.OutCubic
                    }
                }
                displaced: Transition {
                    NumberAnimation {
                        properties: "x,y"
                        duration: 200
                        easing.type: Easing.OutCubic
                    }
                }
                remove: Transition {
                    NumberAnimation {
                        property: "opacity"
                        to: 0
                        duration: 150
                    }
                }
                visible: root.recentBlocksList.length > 0
                Layout.fillWidth: true
                Layout.preferredHeight: 380
                clip: true
                spacing: Theme.spacing.small
                boundsBehavior: Flickable.StopAtBounds
                ScrollBar.vertical: LogosScrollBar {
                    parent: blocksList.parent
                    anchors.top: blocksList.top
                    anchors.bottom: blocksList.bottom
                    anchors.left: blocksList.right
                    anchors.leftMargin: 4
                }
                model: root.recentBlocksList
                delegate: Rectangle {
                    width: ListView.view.width
                    radius: Theme.spacing.radiusLarge
                    color: Theme.palette.backgroundSecondary
                    implicitHeight: 52
                    RowLayout {
                        anchors {
                            left: parent.left
                            right: parent.right
                            verticalCenter: parent.verticalCenter
                            leftMargin: Theme.spacing.medium
                            rightMargin: Theme.spacing.medium
                        }
                        spacing: Theme.spacing.medium
                        ColumnLayout {
                            spacing: 1
                            LogosText {
                                text: "#" + root.fmt(modelData.height)
                                color: Theme.palette.text
                                font.pixelSize: Theme.typography.primaryText
                                font.weight: Theme.typography.weightBold
                            }
                            LogosText {
                                text: "slot " + root.fmt(modelData.slot)
                                color: Theme.palette.textTertiary
                                font.pixelSize: 10
                            }
                        }
                        Mono {
                            Layout.fillWidth: true
                            text: root.shortHex(String(modelData.id))
                            color: Theme.palette.textSecondary
                            horizontalAlignment: Text.AlignRight
                            elide: Text.ElideMiddle
                        }
                        Chip {
                            label: modelData.txCount > 0 ? (modelData.txCount + (modelData.txCount === 1 ? " tx" : " txs")) : "empty"
                            tint: modelData.txCount > 0 ? Theme.palette.primary : Theme.palette.textTertiary
                        }
                    }
                }
            }
            RowLayout {
                Layout.fillWidth: true
                Item {
                    Layout.fillWidth: true
                }
                ActionButton {
                    text: "Close"
                    onClicked: blocksOverlay.visible = false
                }
            }
        }
    }

    // ── First-run onboarding: create-with-seed or restore ────────────
    // Full-screen gate shown until the private wallet exists. Base-chain
    // node setup stays separate (its keys aren't seed-derived).
    Rectangle {
        id: onbOverlay
        objectName: "onbOverlay"
        visible: root.onbActive
        anchors.fill: parent
        z: 200
        color: Theme.palette.background
        MouseArea {
            anchors.fill: parent
            hoverEnabled: true
        }
        // faint brand wash from the top
        Rectangle {
            anchors.fill: parent
            gradient: Gradient {
                GradientStop {
                    position: 0.0
                    color: Theme.colors.getColor(Theme.palette.primary, 0.06)
                }
                GradientStop {
                    position: 0.5
                    color: "transparent"
                }
            }
        }
        ColumnLayout {
            anchors.centerIn: parent
            width: Math.min(parent.width - Theme.spacing.xxlarge * 2, 560)
            spacing: Theme.spacing.large
            opacity: onbOverlay.visible ? 1 : 0
            scale: onbOverlay.visible ? 1 : 0.98
            Behavior on opacity {
                NumberAnimation {
                    duration: 240
                    easing.type: Easing.OutCubic
                }
            }
            Behavior on scale {
                NumberAnimation {
                    duration: 260
                    easing.type: Easing.OutCubic
                }
            }

            // Brand header — every step
            RowLayout {
                Layout.alignment: Qt.AlignHCenter
                spacing: Theme.spacing.medium
                Image {
                    source: "icons/logos-wallet.png"
                    Layout.preferredWidth: 44
                    Layout.preferredHeight: 44
                    sourceSize: Qt.size(128, 128)
                    smooth: true
                }
                LogosText {
                    text: "Persona"
                    color: Theme.palette.text
                    font.pixelSize: Theme.typography.panelTitleText
                    font.weight: Theme.typography.weightBold
                }
            }

            // Step dots — fixed under the header so they never move as the
            // card height changes per step.
            RowLayout {
                Layout.alignment: Qt.AlignHCenter
                Layout.topMargin: Theme.spacing.tiny
                spacing: Theme.spacing.small
                visible: root.onbStep <= 2
                Repeater {
                    model: 3
                    delegate: Rectangle {
                        implicitWidth: root.onbStep === index ? 22 : 8
                        implicitHeight: 8
                        radius: 4
                        color: root.onbStep === index ? Theme.palette.primary : Theme.palette.borderSubtle
                        Behavior on implicitWidth {
                            NumberAnimation {
                                duration: 200
                                easing.type: Easing.OutCubic
                            }
                        }
                        Behavior on color {
                            ColorAnimation {
                                duration: 200
                            }
                        }
                    }
                }
            }

            // ── Create-flow carousel: welcome → phrase → confirm ──
            SwipeView {
                id: onbSwipe
                Layout.fillWidth: true
                // Fixed to the 24-word recovery-phrase step (the tallest). A
                // constant height keeps the whole centered block — and the dots
                // — from shifting as you move between steps.
                Layout.preferredHeight: 466
                currentIndex: Math.min(root.onbStep, 2)
                interactive: false
                clip: true
                visible: root.onbStep <= 2
                onCurrentIndexChanged: if (currentIndex === 2) {
                    vfA.text = "";
                    vfB.text = "";
                    vfC.text = "";
                }
                Item {
                    implicitHeight: card0.implicitHeight
                    Card {
                        id: card0
                        anchors.fill: parent
                        glow: true
                        Item {
                            Layout.fillHeight: true
                        }
                        LogosText {
                            text: "Set up your wallet"
                            color: Theme.palette.text
                            font.pixelSize: Theme.typography.subtitleText
                            font.weight: Theme.typography.weightBold
                        }
                        LogosText {
                            Layout.fillWidth: true
                            wrapMode: Text.Wrap
                            color: Theme.palette.textSecondary
                            font.pixelSize: Theme.typography.primaryText
                            text: "Your private wallet on the Logos network — where your hidden balance lives."
                        }
                        ColumnLayout {
                            Layout.fillWidth: true
                            Layout.topMargin: Theme.spacing.tiny
                            Layout.bottomMargin: Theme.spacing.tiny
                            spacing: Theme.spacing.medium
                            Repeater {
                                model: ["Amounts and participants stay private — hidden from everyone.", "You hold the keys — no account, no sign-up.", "One recovery phrase backs your whole wallet up."]
                                delegate: RowLayout {
                                    required property string modelData
                                    Layout.fillWidth: true
                                    spacing: Theme.spacing.small
                                    Rectangle {
                                        Layout.alignment: Qt.AlignTop
                                        Layout.topMargin: 7
                                        implicitWidth: 6
                                        implicitHeight: 6
                                        radius: 3
                                        color: Theme.palette.primary
                                    }
                                    LogosText {
                                        Layout.fillWidth: true
                                        text: parent.modelData
                                        color: Theme.palette.textSecondary
                                        font.pixelSize: Theme.typography.secondaryText
                                        wrapMode: Text.Wrap
                                    }
                                }
                            }
                        }
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: Theme.spacing.medium
                            ActionButton {
                                accent: true
                                // If a wallet was already created this session (came
                                // back from the phrase step), re-show it instead of
                                // re-creating — never strands the user without their seed.
                                text: root.lezBusy ? "Creating your wallet…" : (root.lezMnemonic.length > 0 ? "Resume setup" : "Create a new wallet")
                                enabled: !root.lezBusy
                                onClicked: root.onbPreview ? root.onbPreviewSeed() : (root.lezMnemonic.length > 0 ? (root.onbStep = 1) : root.onbCreate())
                            }
                            ActionButton {
                                visible: root.lezMnemonic.length === 0
                                text: "I already have a recovery phrase"
                                enabled: !root.lezBusy
                                onClicked: root.onbStep = 3
                            }
                            Item {
                                Layout.fillWidth: true
                            }
                        }
                        RowLayout {
                            visible: root.lezBusy
                            spacing: Theme.spacing.small
                            LogosSpinner {
                                running: parent.visible
                                implicitWidth: 18
                                implicitHeight: 18
                                thickness: 2
                                dotSize: 4
                                ringColor: Theme.palette.primary
                            }
                            LogosText {
                                text: "Setting things up — this takes a few seconds."
                                color: Theme.palette.textTertiary
                                font.pixelSize: Theme.typography.secondaryText
                            }
                        }
                        Item {
                            Layout.fillHeight: true
                        }
                    }
                }
                Item {
                    implicitHeight: card1.implicitHeight
                    Card {
                        id: card1
                        anchors.fill: parent
                        Item {
                            Layout.fillHeight: true
                        }
                        LogosText {
                            text: "Your recovery phrase"
                            color: Theme.palette.text
                            font.pixelSize: Theme.typography.subtitleText
                            font.weight: Theme.typography.weightBold
                        }
                        Rectangle {
                            Layout.fillWidth: true
                            color: Theme.colors.getColor(Theme.palette.warning, 0.10)
                            border.color: Theme.colors.getColor(Theme.palette.warning, 0.45)
                            border.width: 1
                            radius: Theme.spacing.radiusMedium
                            implicitHeight: warnT.implicitHeight + Theme.spacing.medium * 2
                            LogosText {
                                id: warnT
                                anchors {
                                    left: parent.left
                                    right: parent.right
                                    verticalCenter: parent.verticalCenter
                                    margins: Theme.spacing.medium
                                }
                                wrapMode: Text.Wrap
                                text: "⚠ The only way to recover your wallet. Write them down in order, keep them offline, and never share them."
                                color: Theme.palette.warning
                                font.pixelSize: Theme.typography.secondaryText
                            }
                        }
                        Flow {
                            Layout.fillWidth: true
                            spacing: Theme.spacing.small
                            Repeater {
                                model: root.lezMnemonic.trim().length > 0 ? root.lezMnemonic.trim().split(/\s+/) : []
                                delegate: Rectangle {
                                    radius: Theme.spacing.radiusMedium
                                    color: Theme.palette.backgroundTertiary
                                    border.width: 1
                                    border.color: Theme.palette.borderHairline
                                    implicitWidth: chipT.implicitWidth + 14
                                    implicitHeight: 27
                                    LogosText {
                                        id: chipT
                                        anchors.centerIn: parent
                                        text: index + 1 + ". " + modelData
                                        font.family: "Menlo"
                                        font.pixelSize: 11
                                        color: Theme.palette.text
                                    }
                                }
                            }
                        }
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: Theme.spacing.small
                            ActionButton {
                                text: root.copied === "onbmn" ? "✓ Copied" : "Copy phrase"
                                onClicked: root.copy(root.lezMnemonic, "onbmn")
                            }
                            Item {
                                Layout.fillWidth: true
                            }
                        }
                        LogosCheckbox {
                            id: onbSavedBox
                            text: "I've written these words down and stored them safely"
                            onClicked: root.onbSaved = checked
                        }
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: Theme.spacing.small
                            ActionButton {
                                text: "Back"
                                onClicked: root.onbStep = 0
                            }
                            Item {
                                Layout.fillWidth: true
                            }
                            ActionButton {
                                accent: true
                                text: "Continue"
                                enabled: root.onbSaved
                                onClicked: root.onbToVerify()
                            }
                        }
                        Item {
                            Layout.fillHeight: true
                        }
                    }
                }
                Item {
                    implicitHeight: card2.implicitHeight
                    Card {
                        id: card2
                        anchors.fill: parent
                        Item {
                            Layout.fillHeight: true
                        }
                        LogosText {
                            text: "Confirm your recovery phrase"
                            color: Theme.palette.text
                            font.pixelSize: Theme.typography.subtitleText
                            font.weight: Theme.typography.weightBold
                        }
                        LogosText {
                            Layout.fillWidth: true
                            wrapMode: Text.Wrap
                            color: Theme.palette.textSecondary
                            font.pixelSize: Theme.typography.primaryText
                            text: "Type the missing words to confirm you saved them."
                        }
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: Theme.spacing.small
                            FormLabel {
                                text: "Word #" + (root.onbVerifyIdx.length > 0 ? root.onbVerifyIdx[0] + 1 : "")
                            }
                            LogosTextField {
                                id: vfA
                                Layout.fillWidth: true
                                placeholderText: "…"
                            }
                        }
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: Theme.spacing.small
                            FormLabel {
                                text: "Word #" + (root.onbVerifyIdx.length > 1 ? root.onbVerifyIdx[1] + 1 : "")
                            }
                            LogosTextField {
                                id: vfB
                                Layout.fillWidth: true
                                placeholderText: "…"
                            }
                        }
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: Theme.spacing.small
                            FormLabel {
                                text: "Word #" + (root.onbVerifyIdx.length > 2 ? root.onbVerifyIdx[2] + 1 : "")
                            }
                            LogosTextField {
                                id: vfC
                                Layout.fillWidth: true
                                placeholderText: "…"
                            }
                        }
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: Theme.spacing.small
                            ActionButton {
                                text: "Back"
                                onClicked: root.onbStep = 1
                            }
                            Item {
                                Layout.fillWidth: true
                            }
                            ActionButton {
                                accent: true
                                text: "Finish setup"
                                enabled: root.onbPreview || root.onbVerifyOk([vfA.text, vfB.text, vfC.text])
                                onClicked: root.onbFinish()
                            }
                        }
                        Item {
                            Layout.fillHeight: true
                        }
                    }
                }
            }

            // ── Restore — separate side-path (reached from welcome) ──
            Card {
                visible: root.onbStep === 3
                LogosText {
                    text: "Restore your wallet"
                    color: Theme.palette.text
                    font.pixelSize: Theme.typography.subtitleText
                    font.weight: Theme.typography.weightBold
                }
                LogosText {
                    Layout.fillWidth: true
                    wrapMode: Text.Wrap
                    color: Theme.palette.textSecondary
                    font.pixelSize: Theme.typography.primaryText
                    text: "Enter your 12 or 24-word recovery phrase, separated by spaces."
                }
                LogosTextArea {
                    id: onbImportField
                    Layout.fillWidth: true
                    Layout.preferredHeight: 96
                    placeholderText: "word one  word two  word three  …"
                    enabled: !root.lezBusy
                }
                LogosText {
                    visible: root.lastError.length > 0
                    Layout.fillWidth: true
                    wrapMode: Text.Wrap
                    text: "Couldn't restore: " + root.lastError
                    color: Theme.palette.error
                    font.pixelSize: Theme.typography.secondaryText
                }
                RowLayout {
                    Layout.fillWidth: true
                    spacing: Theme.spacing.small
                    ActionButton {
                        text: "Back"
                        enabled: !root.lezBusy
                        onClicked: root.onbStep = 0
                    }
                    Item {
                        Layout.fillWidth: true
                    }
                    ActionButton {
                        accent: true
                        text: root.lezBusy ? "Restoring…" : "Restore wallet"
                        enabled: root.onbPreview || (!root.lezBusy && (onbImportField.text.trim().split(/\s+/).length === 12 || onbImportField.text.trim().split(/\s+/).length === 24))
                        onClicked: root.onbPreview ? root.onbFinish() : root.lezRestoreWallet(onbImportField.text)
                    }
                }
            }
        }
    }

    // ── BASE CHAIN TAB ───────────────────────────────────────────────
    Component {
        id: bedrockTab
        ColumnLayout {
            id: bcol
            width: parent ? parent.width : root.width
            height: parent ? parent.height : root.height
            spacing: Theme.spacing.large
            readonly property bool wide: width >= 900
            // gentle fade-in each time this tab is shown
            opacity: 0
            Component.onCompleted: opacity = 1
            Behavior on opacity {
                NumberAnimation {
                    duration: 220
                    easing.type: Easing.OutCubic
                }
            }

            // Center onboarding/starting content vertically until the main
            // grid (which fills the viewport) takes over.
            Item {
                visible: root.nodeStatus !== 3
                Layout.fillHeight: true
            }

            // Before the first status reply, show a neutral placeholder — never
            // the welcome card — so an already-running node doesn't flash it.
            Card {
                visible: !root.baseStatusKnown && root.nodeStatus !== 3
                RowLayout {
                    Layout.fillWidth: true
                    spacing: Theme.spacing.medium
                    LogosSpinner {
                        running: true
                        implicitWidth: 20
                        implicitHeight: 20
                        thickness: 2
                        dotSize: 4
                        ringColor: Theme.palette.primary
                    }
                    LogosText {
                        text: "Checking your node…"
                        color: Theme.palette.textSecondary
                        font.pixelSize: Theme.typography.primaryText
                    }
                }
            }

            // Welcome / start node — shown until the node is running
            Card {
                visible: root.nodeStatus === 0 && root.baseStatusKnown
                glow: true
                LogosText {
                    text: "Welcome to your wallet"
                    color: Theme.palette.text
                    font.pixelSize: Theme.typography.panelTitleText
                    font.weight: Theme.typography.weightBold
                }
                LogosText {
                    Layout.fillWidth: true
                    wrapMode: Text.Wrap
                    color: Theme.palette.textSecondary
                    font.pixelSize: Theme.typography.primaryText
                    text: "Your own node, your own keys — no account, no sign-up."
                }
                GridLayout {
                    Layout.fillWidth: true
                    columns: bcol.wide ? 3 : 1
                    columnSpacing: Theme.spacing.medium
                    rowSpacing: Theme.spacing.medium
                    StepTile {
                        num: 1
                        text: "Start your node. The first start takes a few minutes while it downloads and sets up."
                    }
                    StepTile {
                        num: 2
                        text: "Get free test tokens from the faucet — this is a test network, so they cost nothing."
                    }
                    StepTile {
                        num: 3
                        text: "Send tokens to a friend, or inscribe a permanent message onto the chain."
                    }
                }
                RowLayout {
                    spacing: Theme.spacing.medium
                    ActionButton {
                        accent: true
                        text: "Start node"
                        onClicked: root.startNode()
                    }
                }
            }

            // Overview — balance + node status (once starting/running)
            Card {
                id: baseHero
                visible: root.nodeStatus !== 0
                glow: true
                property bool showDetails: false
                RowLayout {
                    Layout.fillWidth: true
                    spacing: Theme.spacing.medium
                    HeroBalance {
                        caption: "Base balance"
                        value: (root.nodeStatus === 3 && root.baseAccountsLoaded) ? root.fmt(root.baseAccounts.reduce(function (a, x) {
                            return a + (Number(x.balance) || 0);
                        }, 0)) : "…"
                        sub: root.nodeStatus === 3 ? "" : "appears once the node is running"
                        tip: "Tokens on the Logos base chain. Every transfer here is public."
                    }
                    Item {
                        Layout.fillWidth: true
                    }
                    RowLayout {
                        Layout.alignment: Qt.AlignTop
                        spacing: Theme.spacing.small
                        LogosSpinner {
                            visible: root.nodeStatus === 1
                            running: visible
                            implicitWidth: 20
                            implicitHeight: 20
                            thickness: 2
                            dotSize: 4
                            ringColor: Theme.palette.primary
                        }
                        StatusPill {
                            c: root.nodeStatus === 3 ? (root.chainMode === "Online" ? Theme.palette.success : Theme.palette.warning) : Theme.palette.warning
                            pulsing: root.nodeStatus === 1 || (root.nodeStatus === 3 && root.chainMode !== "Online")
                            label: root.nodeStatus === 1 ? (root.nodeStage.length ? "Starting — " + root.nodeStage + "…" : "Starting…") : (root.chainMode === "Online" ? "Node online" : "Syncing…")
                            tip: root.nodeStatus === 1 ? "First start takes a few minutes — the node is downloading and setting up." : (root.chainMode !== "Online" ? "This 0.2.0 node reports “Bootstrapping” even when caught up — that's normal." : "")
                        }
                        MiniButton {
                            id: nodeMenuBtn
                            visible: root.nodeStatus === 3
                            label: "⋯"
                            tip: "Node actions"
                            onClicked: nodeMenu.popup(nodeMenuBtn, 0, nodeMenuBtn.height + 6)
                        }
                        LogosMenu {
                            id: nodeMenu
                            LogosMenuItem {
                                text: "Recent blocks"
                                onTriggered: {
                                    blocksOverlay.open();
                                    root.loadRecentBlocks();
                                }
                            }
                            LogosMenuItem {
                                text: "Node info"
                                onTriggered: nodeInfoOverlay.open()
                            }
                            LogosMenuSeparator {}
                            LogosMenuItem {
                                text: "Stop node"
                                onTriggered: root.stopNode()
                            }
                        }
                    }
                }
                RowLayout {
                    visible: root.nodeStatus === 3
                    Layout.fillWidth: true
                    MiniButton {
                        label: baseHero.showDetails ? "Hide node details" : "Node details"
                        onClicked: baseHero.showDetails = !baseHero.showDetails
                    }
                    Item {
                        Layout.fillWidth: true
                    }
                }
                RowLayout {
                    visible: root.nodeStatus === 3 && baseHero.showDetails
                    Layout.fillWidth: true
                    spacing: Theme.spacing.small
                    StatTile {
                        label: "Block height"
                        value: root.fmt(root.chainHeight)
                    }
                    StatTile {
                        label: "Slot"
                        value: root.fmt(root.chainSlot)
                    }
                    StatTile {
                        label: "Peers"
                        value: root.nPeers >= 0 ? String(root.nPeers) : "—"
                    }
                    StatTile {
                        label: "Connections"
                        value: root.nConnections >= 0 ? String(root.nConnections) : "—"
                    }
                }
            }

            // Two-column content grid on wide viewports
            GridLayout {
                Layout.fillWidth: true
                Layout.fillHeight: true
                visible: root.nodeStatus === 3
                columns: bcol.wide ? 2 : 1
                columnSpacing: Theme.spacing.large
                rowSpacing: Theme.spacing.large

                // Left column — accounts
                ColumnLayout {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    Layout.preferredWidth: 100
                    Layout.alignment: Qt.AlignTop
                    spacing: Theme.spacing.large

                    // Accounts
                    Card {
                        visible: root.nodeStatus === 3
                        Layout.fillHeight: true
                        title: "Accounts"
                        tip: "An address works like an account number — share it and people can send you tokens."
                        ColumnLayout {
                            visible: !root.baseAccountsLoaded
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            spacing: Theme.spacing.small
                            SkeletonRow {}
                            SkeletonRow {}
                            Item {
                                Layout.fillHeight: true
                            }
                        }
                        ListView {
                            id: baseAcctList
                            add: Transition {
                                NumberAnimation {
                                    property: "opacity"
                                    from: 0
                                    to: 1
                                    duration: 220
                                    easing.type: Easing.OutCubic
                                }
                            }
                            displaced: Transition {
                                NumberAnimation {
                                    properties: "x,y"
                                    duration: 200
                                    easing.type: Easing.OutCubic
                                }
                            }
                            remove: Transition {
                                NumberAnimation {
                                    property: "opacity"
                                    to: 0
                                    duration: 150
                                }
                            }
                            visible: root.baseAccountsLoaded
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            Layout.minimumHeight: 60
                            clip: true
                            spacing: Theme.spacing.small
                            boundsBehavior: Flickable.StopAtBounds
                            // Sits in the card's padding gutter so it never
                            // overlaps the rows.
                            ScrollBar.vertical: LogosScrollBar {
                                parent: baseAcctList.parent
                                anchors.top: baseAcctList.top
                                anchors.bottom: baseAcctList.bottom
                                anchors.left: baseAcctList.right
                                anchors.leftMargin: 4
                            }
                            model: root.baseAccounts
                            delegate: Rectangle {
                                width: ListView.view.width
                                radius: Theme.spacing.radiusLarge
                                color: baseRowMa.containsMouse ? Theme.palette.backgroundButton : Theme.palette.backgroundSecondary
                                implicitHeight: 48
                                Behavior on color {
                                    ColorAnimation {
                                        duration: 120
                                    }
                                }
                                MouseArea {
                                    id: baseRowMa
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    acceptedButtons: Qt.NoButton
                                }
                                RowLayout {
                                    anchors {
                                        left: parent.left
                                        right: parent.right
                                        verticalCenter: parent.verticalCenter
                                        leftMargin: Theme.spacing.medium
                                        rightMargin: Theme.spacing.medium
                                    }
                                    spacing: Theme.spacing.small
                                    AccountAvatar {
                                        seed: String(modelData.address)
                                    }
                                    LogosBadge {
                                        visible: modelData.role === "LeaderFunding"
                                        text: "Main"
                                        color: Theme.palette.primary
                                    }
                                    LogosText {
                                        visible: modelData.role !== "LeaderFunding"
                                        text: root.baseRoleInfo(modelData.role).name
                                        color: Theme.palette.textSecondary
                                        font.pixelSize: 11
                                        font.weight: Theme.typography.weightMedium
                                    }
                                    InfoTip {
                                        tip: root.baseRoleInfo(modelData.role).desc
                                    }
                                    Mono {
                                        text: root.shortHex(modelData.address)
                                    }
                                    MiniButton {
                                        label: root.copied === modelData.address ? "✓ Copied" : "Copy"
                                        onClicked: root.copy(modelData.address, modelData.address)
                                    }
                                    Item {
                                        Layout.fillWidth: true
                                    }
                                    LogosText {
                                        text: root.fmt(modelData.balance)
                                        color: Number(modelData.balance) > 0 ? Theme.palette.text : Theme.palette.textMuted
                                        font.pixelSize: Theme.typography.primaryText
                                        font.weight: Theme.typography.weightBold
                                    }
                                }
                            }
                        }
                        Hairline {}
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: Theme.spacing.small
                            LogosText {
                                Layout.fillWidth: true
                                text: "Need test tokens?"
                                color: Theme.palette.textSecondary
                                font.pixelSize: Theme.typography.secondaryText
                            }
                            MiniButton {
                                label: "Open faucet ↗"
                                tip: "Copy your Main address, paste it at the faucet, and it sends you free test tokens."
                                onClicked: Qt.openUrlExternally("https://testnet.blockchain.logos.co/web/faucet/")
                            }
                        }
                    }
                }

                // Right column — actions
                ColumnLayout {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    Layout.preferredWidth: 100
                    Layout.alignment: Qt.AlignTop
                    spacing: Theme.spacing.large

                    // Send
                    Card {
                        id: baseSendCard
                        visible: root.nodeStatus === 3
                        title: "Send"
                        tip: "Base-chain transfers are public — anyone can look them up. For hidden payments, use the LEZ (Zone) tab."

                        // selected paying account (or null) + its balance
                        property var fromAcct: (baseFromBox.currentIndex >= 0 && root.baseAccounts.length > baseFromBox.currentIndex) ? root.baseAccounts[baseFromBox.currentIndex] : null
                        property string fromAddr: fromAcct ? String(fromAcct.address) : ""
                        property double fromBal: fromAcct ? Number(fromAcct.balance) || 0 : 0
                        property bool amtOver: Number(sendAmtField.text) > fromBal
                        property bool fromSpendable: fromAcct ? root.baseRoleInfo(fromAcct.role).spendable : true

                        // FROM — pick which account pays
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: Theme.spacing.small
                            FormLabel {
                                text: "From"
                            }
                            LogosComboBox {
                                id: baseFromBox
                                objectName: "baseFromBox"
                                Layout.fillWidth: true
                                implicitHeight: 36
                                enabled: !root.sendBusy && root.baseAccountsLoaded
                                model: root.baseAccounts
                                // ComboBox resets currentIndex to 0 whenever the
                                // model is assigned and clobbers a currentIndex
                                // binding, so default to Main explicitly (after
                                // its internal reset) each time the set changes.
                                function defaultToMain() {
                                    if (count > 0)
                                        currentIndex = root.baseMainIndex();
                                }
                                onModelChanged: Qt.callLater(defaultToMain)
                                Component.onCompleted: defaultToMain()
                                placeholderText: "No accounts yet"
                                displayText: baseFromBox.currentIndex >= 0 ? root.baseFromLabel(root.baseAccounts[baseFromBox.currentIndex]) : ""
                                delegate: ItemDelegate {
                                    id: baseFromDelegate
                                    width: baseFromBox.width
                                    highlighted: baseFromBox.highlightedIndex === index
                                    contentItem: LogosText {
                                        text: root.baseFromLabel(modelData)
                                        font.pixelSize: Theme.typography.secondaryText
                                        color: Theme.palette.text
                                        verticalAlignment: Text.AlignVCenter
                                        elide: Text.ElideRight
                                    }
                                    background: Rectangle {
                                        color: baseFromDelegate.highlighted ? Theme.palette.surface : "transparent"
                                    }
                                }
                            }
                        }
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: Theme.spacing.small
                            FormLabel {
                                text: "To"
                            }
                            LogosTextField {
                                id: sendToField
                                Layout.fillWidth: true
                                placeholderText: "Paste the recipient's address…"
                                enabled: !root.sendBusy
                                Component.onCompleted: textInput.font.family = "Menlo"
                            }
                        }
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: Theme.spacing.small
                            FormLabel {
                                text: "Amount"
                            }
                            LogosTextField {
                                id: sendAmtField
                                objectName: "sendAmtField"
                                Layout.preferredWidth: 130
                                placeholderText: "0"
                                enabled: !root.sendBusy
                                Component.onCompleted: textInput.validator = intValidator
                            }
                            LogosText {
                                visible: root.lastSendTx.length > 0
                                text: "Sent ✓ receipt " + root.shortHex(root.lastSendTx)
                                color: Theme.palette.success
                                font.pixelSize: Theme.typography.secondaryText
                                Layout.leftMargin: Theme.spacing.small
                            }
                            Item {
                                Layout.fillWidth: true
                            }
                            ActionButton {
                                accent: true
                                text: root.sendBusy ? "Sending…" : "Send"
                                enabled: !root.sendBusy && baseSendCard.fromAddr.length === 64 && /^[0-9a-fA-F]{64}$/.test(sendToField.text.trim()) && Number(sendAmtField.text) > 0 && !baseSendCard.amtOver
                                onClicked: root.baseSend(baseSendCard.fromAddr, sendToField.text.trim(), sendAmtField.text.trim())
                            }
                        }
                        LogosText {
                            visible: sendToField.text.trim().length > 0 && !/^[0-9a-fA-F]{64}$/.test(sendToField.text.trim())
                            Layout.fillWidth: true
                            wrapMode: Text.Wrap
                            text: "That address doesn't look right — it should be exactly 64 letters (a–f) and numbers. Double-check what you pasted."
                            color: Theme.palette.warning
                            font.pixelSize: 11
                        }
                        LogosText {
                            visible: baseSendCard.fromAcct !== null && baseSendCard.amtOver && Number(sendAmtField.text) > 0
                            Layout.fillWidth: true
                            wrapMode: Text.Wrap
                            text: baseSendCard.fromAcct ? "That's more than the " + root.baseRoleInfo(baseSendCard.fromAcct.role).name + " account holds (" + root.fmt(baseSendCard.fromBal) + "). Pick another account or lower the amount." : ""
                            color: Theme.palette.warning
                            font.pixelSize: 11
                        }
                        LogosText {
                            visible: baseSendCard.fromAcct !== null && !baseSendCard.fromSpendable
                            Layout.fillWidth: true
                            wrapMode: Text.Wrap
                            text: baseSendCard.fromAcct ? "⚠ " + root.baseRoleInfo(baseSendCard.fromAcct.role).name + " is one of your node's protocol keys, not a spending wallet. " + root.baseRoleInfo(baseSendCard.fromAcct.role).desc + " Only send from it if you know exactly what you're doing — switch to Main above for normal payments." : ""
                            color: Theme.palette.warning
                            font.pixelSize: 11
                        }
                    }

                    // Inscribe — stretches so the two columns end flush
                    Card {
                        visible: root.nodeStatus === 3
                        Layout.fillHeight: true
                        title: "Inscribe"
                        tip: "Carve a short message onto the base chain — public, permanent, never editable or deletable."
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: Theme.spacing.small
                            FormLabel {
                                text: "Message"
                            }
                            LogosTextField {
                                id: inscribeField
                                Layout.fillWidth: true
                                placeholderText: "Say something for the ages…"
                                enabled: !root.inscribeBusy
                            }
                            ActionButton {
                                accent: true
                                text: root.inscribeBusy ? "Inscribing…" : "Inscribe"
                                enabled: !root.inscribeBusy && inscribeField.text.trim().length > 0
                                onClicked: root.inscribe(inscribeField.text.trim())
                            }
                        }
                        LogosText {
                            visible: root.lastInscribe.length > 0
                            text: root.lastInscribe
                            color: Theme.palette.success
                            font.pixelSize: Theme.typography.secondaryText
                        }
                        Hairline {}
                        // Recent inscriptions — anyone's text messages on-chain
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: Theme.spacing.small
                            LogosText {
                                text: "Recent inscriptions"
                                color: Theme.palette.textTertiary
                                font.pixelSize: 10
                                font.weight: Theme.typography.weightMedium
                                font.letterSpacing: 0.8
                                font.capitalization: Font.AllUppercase
                            }
                            InfoTip {
                                tip: "Text messages inscribed onto the base chain by anyone running a node — read from recent blocks. The LEZ zone's own on-chain data is filtered out."
                            }
                            Item {
                                Layout.fillWidth: true
                            }
                            MiniButton {
                                label: root.inscFeedLoading ? "Loading…" : "Refresh"
                                tip: "Re-scan recent blocks for new inscriptions."
                                onClicked: root.loadInscFeed()
                            }
                        }
                        ColumnLayout {
                            visible: root.inscFeedLoading && root.inscFeed.length === 0
                            Layout.fillWidth: true
                            spacing: Theme.spacing.small
                            SkeletonRow {}
                            SkeletonRow {}
                        }
                        LogosText {
                            visible: root.inscFeedLoaded && !root.inscFeedLoading && root.inscFeed.length === 0
                            Layout.fillWidth: true
                            wrapMode: Text.Wrap
                            text: "No text inscriptions in recent blocks yet."
                            color: Theme.palette.textTertiary
                            font.pixelSize: Theme.typography.secondaryText
                        }
                        ListView {
                            id: inscFeedList
                            add: Transition {
                                NumberAnimation {
                                    property: "opacity"
                                    from: 0
                                    to: 1
                                    duration: 220
                                    easing.type: Easing.OutCubic
                                }
                            }
                            displaced: Transition {
                                NumberAnimation {
                                    properties: "x,y"
                                    duration: 200
                                    easing.type: Easing.OutCubic
                                }
                            }
                            remove: Transition {
                                NumberAnimation {
                                    property: "opacity"
                                    to: 0
                                    duration: 150
                                }
                            }
                            visible: root.inscFeed.length > 0
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            Layout.minimumHeight: 60
                            clip: true
                            spacing: Theme.spacing.small
                            boundsBehavior: Flickable.StopAtBounds
                            ScrollBar.vertical: LogosScrollBar {
                                parent: inscFeedList.parent
                                anchors.top: inscFeedList.top
                                anchors.bottom: inscFeedList.bottom
                                anchors.left: inscFeedList.right
                                anchors.leftMargin: 4
                            }
                            model: root.inscFeed
                            delegate: Rectangle {
                                width: ListView.view.width
                                radius: Theme.spacing.radiusLarge
                                color: Theme.palette.backgroundSecondary
                                implicitHeight: inscRow.implicitHeight + Theme.spacing.medium * 2
                                RowLayout {
                                    id: inscRow
                                    anchors {
                                        left: parent.left
                                        right: parent.right
                                        verticalCenter: parent.verticalCenter
                                        leftMargin: Theme.spacing.medium
                                        rightMargin: Theme.spacing.medium
                                    }
                                    spacing: Theme.spacing.small
                                    AccountAvatar {
                                        seed: String(modelData.signer)
                                        Layout.alignment: Qt.AlignTop
                                    }
                                    ColumnLayout {
                                        Layout.fillWidth: true
                                        spacing: 2
                                        LogosText {
                                            Layout.fillWidth: true
                                            text: modelData.text
                                            color: Theme.palette.text
                                            font.pixelSize: Theme.typography.primaryText
                                            wrapMode: Text.Wrap
                                            maximumLineCount: 3
                                            elide: Text.ElideRight
                                        }
                                        LogosText {
                                            text: "by " + root.shortHex(String(modelData.signer)) + " · slot " + root.fmt(modelData.slot)
                                            color: Theme.palette.textTertiary
                                            font.pixelSize: 10
                                        }
                                    }
                                }
                            }
                        }
                        // Absorb slack in the loading/empty states so the card's
                        // spacing matches the populated (list-fills-height) layout.
                        Item {
                            Layout.fillHeight: true
                            visible: root.inscFeed.length === 0
                        }
                    }
                }
            }

            // bottom half of the vertical centering for welcome/starting cards
            Item {
                visible: root.nodeStatus !== 3
                Layout.fillHeight: true
            }
        }
    }

    // ── PRIVATE (LEZ) TAB ────────────────────────────────────────────
    Component {
        id: lezTab
        ColumnLayout {
            id: lcol
            width: parent ? parent.width : root.width
            height: parent ? parent.height : root.height
            spacing: Theme.spacing.large
            readonly property bool wide: width >= 900
            // gentle fade-in each time this tab is shown
            opacity: 0
            Component.onCompleted: opacity = 1
            Behavior on opacity {
                NumberAnimation {
                    duration: 220
                    easing.type: Easing.OutCubic
                }
            }

            // Always-reachable settings row — the sequencer must be editable
            // even when the wallet can't open (that's exactly when it's needed).
            RowLayout {
                Layout.fillWidth: true
                Item {
                    Layout.fillWidth: true
                }
                MiniButton {
                    label: "⚙ Sequencer"
                    tip: "Configure the LEZ sequencer URL this wallet connects to."
                    onClicked: seqOverlay.open()
                }
            }

            // Center onboarding content vertically until the wallet is open
            // and the main grid (which fills the viewport) takes over.
            Item {
                visible: !root.lezReady
                Layout.fillHeight: true
            }

            // Reset leaves the old wallet loaded in the zone module (it has
            // no close) — nothing new can be created until the app restarts.
            NoticeBanner {
                visible: root.lezNeedsRestart
                tint: Theme.palette.warning
                text: "Wallet deleted. Restart Basecamp before creating or restoring a wallet — the old one stays loaded in memory until then."
            }

            // Existing wallet opens itself — show a quiet indicator, no button.
            Card {
                visible: !root.lezReady && root.lezHasWallet
                RowLayout {
                    Layout.fillWidth: true
                    spacing: Theme.spacing.medium
                    LogosSpinner {
                        running: true
                        implicitWidth: 20
                        implicitHeight: 20
                        thickness: 2
                        dotSize: 4
                        ringColor: Theme.palette.primary
                    }
                    LogosText {
                        text: "Opening your private wallet…"
                        color: Theme.palette.textSecondary
                        font.pixelSize: Theme.typography.primaryText
                    }
                }
            }

            // First run only — no wallet on disk yet, so offer to create one.
            Card {
                visible: !root.lezReady && root.lezStatusKnown && !root.lezHasWallet && !root.onbActive
                glow: true
                LogosText {
                    text: "A wallet nobody can spy on"
                    color: Theme.palette.text
                    font.pixelSize: Theme.typography.subtitleText
                    font.weight: Theme.typography.weightBold
                }
                LogosText {
                    Layout.fillWidth: true
                    wrapMode: Text.Wrap
                    color: Theme.palette.textSecondary
                    font.pixelSize: Theme.typography.primaryText
                    text: "Amounts and participants stay hidden on the Logos Execution Zone (LEZ). One click creates it — after that it opens by itself."
                }
                RowLayout {
                    spacing: Theme.spacing.medium
                    ActionButton {
                        accent: true
                        text: root.lezBusy ? "Setting things up…" : "Create my private wallet"
                        enabled: !root.lezBusy && !root.lezNeedsRestart
                        onClicked: root.lezOpen()
                    }
                    LogosSpinner {
                        visible: root.lezBusy
                        running: visible
                        implicitWidth: 20
                        implicitHeight: 20
                        thickness: 2
                        dotSize: 4
                        ringColor: Theme.palette.primary
                    }
                }
                Hairline {}
                RowLayout {
                    Layout.fillWidth: true
                    spacing: Theme.spacing.small
                    LogosTextField {
                        id: restoreField
                        Layout.fillWidth: true
                        placeholderText: "Or paste your 12 or 24 recovery words to restore…"
                        enabled: !root.lezBusy && !root.lezNeedsRestart
                        Component.onCompleted: textInput.font.family = "Menlo"
                    }
                    ActionButton {
                        text: root.lezBusy ? "Restoring…" : "Restore"
                        tip: "Rebuilds the wallet from its recovery phrase. Balances reappear once it re-syncs."
                        enabled: !root.lezBusy && !root.lezNeedsRestart && (restoreField.text.trim().split(/\s+/).length === 12 || restoreField.text.trim().split(/\s+/).length === 24)
                        onClicked: root.lezRestoreWallet(restoreField.text)
                    }
                }
            }

            // Recovery phrase (first run) — numbered word chips
            Rectangle {
                Layout.fillWidth: true
                visible: root.lezMnemonic.length > 0 && !root.onbActive
                color: Theme.colors.getColor(Theme.palette.warning, 0.08)
                border.color: Theme.colors.getColor(Theme.palette.warning, 0.45)
                border.width: 1
                radius: Theme.spacing.radiusLarge
                implicitHeight: mn.implicitHeight + Theme.spacing.large * 2
                ColumnLayout {
                    id: mn
                    anchors {
                        left: parent.left
                        right: parent.right
                        top: parent.top
                        margins: Theme.spacing.large
                    }
                    spacing: Theme.spacing.medium
                    RowLayout {
                        spacing: Theme.spacing.tiny
                        LogosText {
                            text: "Recovery phrase"
                            color: Theme.palette.warning
                            font.pixelSize: 11
                            font.weight: Theme.typography.weightMedium
                            font.letterSpacing: 0.8
                            font.capitalization: Font.AllUppercase
                        }
                        InfoTip {
                            tip: "These words ARE your wallet. Anyone who has them can take your tokens; if you lose them, the wallet cannot be recovered."
                        }
                    }
                    LogosText {
                        Layout.fillWidth: true
                        wrapMode: Text.Wrap
                        color: Theme.palette.textSecondary
                        font.pixelSize: Theme.typography.secondaryText
                        text: "Shown only once — write them down, in order, and keep them safe."
                    }
                    Flow {
                        Layout.fillWidth: true
                        spacing: Theme.spacing.small
                        Repeater {
                            model: root.lezMnemonic.trim().length > 0 ? root.lezMnemonic.trim().split(/\s+/) : []
                            delegate: Rectangle {
                                radius: Theme.spacing.radiusMedium
                                color: Theme.palette.backgroundTertiary
                                border.width: 1
                                border.color: Theme.palette.borderHairline
                                implicitWidth: chipText.implicitWidth + 20
                                implicitHeight: 30
                                LogosText {
                                    id: chipText
                                    anchors.centerIn: parent
                                    text: (index + 1) + ". " + modelData
                                    font.family: "Menlo"
                                    font.pixelSize: Theme.typography.secondaryText
                                    color: Theme.palette.text
                                }
                            }
                        }
                    }
                    RowLayout {
                        spacing: Theme.spacing.small
                        ActionButton {
                            text: root.copied === "mn" ? "✓ Copied" : "Copy words"
                            onClicked: root.copy(root.lezMnemonic, "mn")
                        }
                        ActionButton {
                            accent: true
                            text: "I wrote them down"
                            onClicked: root.lezMnemonic = ""
                        }
                    }
                }
            }

            // Overview — total + private/public split + sync + create
            Card {
                id: lezHero
                visible: root.lezReady
                glow: true
                property double privTotal: root.lezAccountsList.reduce(function (a, x) {
                    return a + (!x.isPublic ? (Number(x.balance) || 0) : 0);
                }, 0)
                property double pubTotal: root.lezAccountsList.reduce(function (a, x) {
                    return a + (x.isPublic ? (Number(x.balance) || 0) : 0);
                }, 0)
                readonly property bool syncing: root.lezHeight >= 0 && root.lezLastSynced < root.lezHeight
                RowLayout {
                    Layout.fillWidth: true
                    spacing: Theme.spacing.medium
                    ColumnLayout {
                        spacing: Theme.spacing.small
                        HeroBalance {
                            caption: "Total balance"
                            value: root.lezAccountsLoaded ? root.fmt(lezHero.privTotal + lezHero.pubTotal) : "…"
                            tip: "Private balances are hidden — only you can see them. Public balances are visible on-chain."
                        }
                        RowLayout {
                            spacing: Theme.spacing.small
                            Chip {
                                visible: root.lezAccountsLoaded
                                label: root.fmt(lezHero.privTotal) + " private"
                                tint: Theme.palette.primary
                            }
                            Chip {
                                visible: root.lezAccountsLoaded
                                label: root.fmt(lezHero.pubTotal) + " public"
                                tint: Theme.palette.info
                            }
                        }
                    }
                    Item {
                        Layout.fillWidth: true
                    }
                    ColumnLayout {
                        Layout.alignment: Qt.AlignTop
                        spacing: Theme.spacing.small
                        StatusPill {
                            Layout.alignment: Qt.AlignRight
                            c: (root.lezBusy || lezHero.syncing) ? Theme.palette.warning : Theme.palette.success
                            pulsing: root.lezBusy || lezHero.syncing
                            label: root.lezBusy ? (root.lezStage.length ? root.lezStage + "…" : "Working…") : lezHero.syncing ? "Syncing…" : "Up to date"
                        }
                        RowLayout {
                            Layout.alignment: Qt.AlignRight
                            spacing: Theme.spacing.small
                            ActionButton {
                                text: "+ Private"
                                enabled: !root.lezCreateBusy && !root.lezBusy
                                onClicked: root.lezCreateAccount("private")
                            }
                            ActionButton {
                                text: "+ Public"
                                enabled: !root.lezCreateBusy && !root.lezBusy
                                onClicked: root.lezCreateAccount("public")
                            }
                            MiniButton {
                                label: "Reset…"
                                tip: "Delete this private wallet from this computer."
                                onClicked: resetOverlay.open()
                            }
                        }
                    }
                }
                LogosText {
                    visible: root.lezMsg.length > 0
                    Layout.fillWidth: true
                    wrapMode: Text.Wrap
                    text: root.lezMsg
                    color: Theme.palette.success
                    font.pixelSize: Theme.typography.secondaryText
                }
            }

            // Two-column content grid on wide viewports
            GridLayout {
                Layout.fillWidth: true
                Layout.fillHeight: true
                visible: root.lezReady
                columns: lcol.wide ? 2 : 1
                columnSpacing: Theme.spacing.large
                rowSpacing: Theme.spacing.large

                // Left column — accounts
                ColumnLayout {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    Layout.preferredWidth: 100
                    Layout.alignment: Qt.AlignTop
                    spacing: Theme.spacing.large

                    // Accounts
                    Card {
                        visible: root.lezReady
                        Layout.fillHeight: true
                        title: "Accounts"
                        tip: "Private accounts hide their balance; public accounts are visible on-chain. Every account derives from your one recovery phrase."
                        LogosText {
                            visible: root.lezAccountsLoaded && root.lezAccountsList.length === 0
                            text: "No accounts yet — create one from the overview above."
                            color: Theme.palette.textTertiary
                            font.pixelSize: Theme.typography.secondaryText
                        }
                        ColumnLayout {
                            visible: !root.lezAccountsLoaded
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            spacing: Theme.spacing.small
                            SkeletonRow {}
                            SkeletonRow {}
                            SkeletonRow {}
                            Item {
                                Layout.fillHeight: true
                            }
                        }
                        ListView {
                            id: lezAcctList
                            add: Transition {
                                NumberAnimation {
                                    property: "opacity"
                                    from: 0
                                    to: 1
                                    duration: 220
                                    easing.type: Easing.OutCubic
                                }
                            }
                            displaced: Transition {
                                NumberAnimation {
                                    properties: "x,y"
                                    duration: 200
                                    easing.type: Easing.OutCubic
                                }
                            }
                            remove: Transition {
                                NumberAnimation {
                                    property: "opacity"
                                    to: 0
                                    duration: 150
                                }
                            }
                            visible: root.lezAccountsLoaded
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            Layout.minimumHeight: 60
                            clip: true
                            spacing: Theme.spacing.small
                            boundsBehavior: Flickable.StopAtBounds
                            // Sits in the card's padding gutter so it never
                            // overlaps the rows.
                            ScrollBar.vertical: LogosScrollBar {
                                parent: lezAcctList.parent
                                anchors.top: lezAcctList.top
                                anchors.bottom: lezAcctList.bottom
                                anchors.left: lezAcctList.right
                                anchors.leftMargin: 4
                            }
                            model: root.lezAccountsList
                            delegate: Rectangle {
                                width: ListView.view.width
                                radius: Theme.spacing.radiusLarge
                                color: lezRowMa.containsMouse ? Theme.palette.backgroundButton : Theme.palette.backgroundSecondary
                                implicitHeight: 52
                                Behavior on color {
                                    ColorAnimation {
                                        duration: 120
                                    }
                                }
                                MouseArea {
                                    id: lezRowMa
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    acceptedButtons: Qt.NoButton
                                }
                                RowLayout {
                                    anchors {
                                        left: parent.left
                                        right: parent.right
                                        verticalCenter: parent.verticalCenter
                                        leftMargin: Theme.spacing.medium
                                        rightMargin: Theme.spacing.medium
                                    }
                                    spacing: Theme.spacing.small
                                    AccountAvatar {
                                        seed: String(modelData.id)
                                    }
                                    LogosBadge {
                                        text: modelData.isPublic ? "Public" : "Private"
                                        color: modelData.isPublic ? Theme.palette.info : Theme.palette.primary
                                    }
                                    Mono {
                                        text: root.shortHex(modelData.idB58)
                                    }
                                    MiniButton {
                                        label: root.copied === modelData.id ? "✓ Copied" : "Copy"
                                        tip: "Copy this account id."
                                        onClicked: root.copy(modelData.idB58, modelData.id)
                                    }
                                    // Private accounts: copy a receiving address to be paid privately.
                                    MiniButton {
                                        visible: !modelData.isPublic
                                        label: root.copied === "recv" ? "✓ Copied" : "Receive"
                                        tip: "Copies a private receiving address (lezpriv1…) — share it to get paid without anyone else seeing."
                                        onClicked: root.lezCopyReceive(modelData.id)
                                    }
                                    Item {
                                        Layout.fillWidth: true
                                    }
                                    LogosText {
                                        text: root.fmt(modelData.balance)
                                        color: Number(modelData.balance) > 0 ? Theme.palette.text : Theme.palette.textMuted
                                        font.pixelSize: Theme.typography.subtitleText
                                        font.weight: Theme.typography.weightBold
                                    }
                                }
                            }
                        }
                    }
                }

                // Right column — funding
                ColumnLayout {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    Layout.preferredWidth: 100
                    Layout.alignment: Qt.AlignTop
                    spacing: Theme.spacing.large

                    // Add funds — same height as the accounts card beside it
                    Card {
                        visible: root.lezReady
                        Layout.fillHeight: true
                        title: "Add funds"
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: Theme.spacing.medium
                            ActionButton {
                                accent: true
                                text: root.lezBusy && root.lezStage === "mining" ? "Mining…" : "Get 150 free tokens"
                                tip: "From the zone's proof-of-work faucet — instant, lands in your public balance first."
                                enabled: !root.lezBusy
                                onClicked: root.lezFund()
                            }
                            Item {
                                Layout.fillWidth: true
                            }
                        }
                        Hairline {
                            visible: Number(root.lezVault) > 0
                        }
                        RowLayout {
                            visible: Number(root.lezVault) > 0
                            Layout.fillWidth: true
                            spacing: Theme.spacing.small
                            LogosText {
                                Layout.fillWidth: true
                                wrapMode: Text.Wrap
                                text: root.fmt(root.lezVault) + " tokens arrived from the base chain — waiting in your vault."
                                color: Theme.palette.primary
                                font.pixelSize: Theme.typography.primaryText
                                font.weight: Theme.typography.weightMedium
                            }
                            ActionButton {
                                accent: true
                                text: "Claim to private"
                                enabled: !root.lezBusy
                                onClicked: root.lezClaimVault(root.lezVault)
                            }
                        }
                        Hairline {
                            visible: Number(root.lezPublicBalance) > 0
                        }
                        RowLayout {
                            visible: Number(root.lezPublicBalance) > 0
                            Layout.fillWidth: true
                            spacing: Theme.spacing.small
                            LogosText {
                                Layout.fillWidth: true
                                wrapMode: Text.Wrap
                                text: root.lezPublicBalance + " tokens still public"
                                color: Theme.palette.text
                                font.pixelSize: Theme.typography.primaryText
                            }
                            ActionButton {
                                text: root.lezBusy && root.lezStage === "transferring" ? "Shielding…" : "Shield to private"
                                tip: "Shielding moves your public tokens into your private balance, hidden from everyone."
                                enabled: !root.lezBusy && root.lezAccountHex.length === 64
                                onClicked: root.lezTransfer("shielded", "", root.lezAccountHex, root.lezPublicBalance)
                            }
                        }
                        Hairline {
                            visible: root.nodeStatus === 3
                        }
                        RowLayout {
                            visible: root.nodeStatus === 3
                            Layout.fillWidth: true
                            spacing: Theme.spacing.small
                            LogosText {
                                text: "Bridge from base chain"
                                color: Theme.palette.textSecondary
                                font.pixelSize: Theme.typography.secondaryText
                            }
                            LogosTextField {
                                id: bridgeAmtField
                                Layout.preferredWidth: 120
                                placeholderText: "Amount"
                                enabled: !root.lezBusy
                                Component.onCompleted: textInput.validator = intValidator
                            }
                            ActionButton {
                                text: root.lezBusy && (root.lezStage === "depositing" || root.lezStage === "waiting-note") ? (root.lezStage + "…") : "Bridge in"
                                tip: "Moves base-chain tokens into the zone. Takes about an hour to reach your vault, then claim it above."
                                enabled: !root.lezBusy && Number(bridgeAmtField.text) > 0
                                onClicked: root.lezBridgeIn(bridgeAmtField.text.trim())
                            }
                            Item {
                                Layout.fillWidth: true
                            }
                        }
                        Item {
                            Layout.fillHeight: true
                        }
                    }
                }
            }

            // Send — explicit sender + recipient. The transfer kind
            // (shield / deshield / private / public) is derived from the
            // sender's type and the chosen recipient type, so the user never
            // has to reason about the jargon.
            Card {
                id: sendCard
                visible: root.lezReady
                title: "Send"
                tip: "Private transfers take up to a minute to prove — that's the privacy math working."

                // selected sender account (or null) + its balance
                property var fromAcct: (fromBox.currentIndex >= 0 && root.lezAccountsList.length > fromBox.currentIndex) ? root.lezAccountsList[fromBox.currentIndex] : null
                property double fromBal: fromAcct ? Number(fromAcct.balance) || 0 : 0
                property bool amtOver: Number(xferAmtField.text) > fromBal

                // FROM — pick which of my accounts pays
                RowLayout {
                    Layout.fillWidth: true
                    spacing: Theme.spacing.small
                    FormLabel {
                        text: "From"
                    }
                    LogosComboBox {
                        id: fromBox
                        Layout.fillWidth: true
                        implicitHeight: 36
                        enabled: !root.lezBusy
                        model: root.lezAccountsList
                        currentIndex: root.lezAccountsList.length > 0 ? 0 : -1
                        placeholderText: "No accounts yet"
                        displayText: fromBox.currentIndex >= 0 ? root.fromLabel(root.lezAccountsList[fromBox.currentIndex]) : ""
                        delegate: ItemDelegate {
                            id: fromDelegate
                            width: fromBox.width
                            highlighted: fromBox.highlightedIndex === index
                            contentItem: LogosText {
                                text: root.fromLabel(modelData)
                                font.pixelSize: Theme.typography.secondaryText
                                color: Theme.palette.text
                                verticalAlignment: Text.AlignVCenter
                                elide: Text.ElideRight
                            }
                            background: Rectangle {
                                color: fromDelegate.highlighted ? Theme.palette.surface : "transparent"
                            }
                        }
                    }
                }

                // TO — recipient address/id + its account type
                RowLayout {
                    Layout.fillWidth: true
                    spacing: Theme.spacing.small
                    FormLabel {
                        text: "To"
                    }
                    LogosTextField {
                        id: xferToField
                        Layout.fillWidth: true
                        placeholderText: destTypeBox.currentValue ? "Recipient's public account id…" : "Recipient's receiving address (starts with lezpriv1)…"
                        enabled: !root.lezBusy
                        Component.onCompleted: textInput.font.family = "Menlo"
                    }
                    LogosComboBox {
                        id: destTypeBox
                        Layout.preferredWidth: 120
                        implicitHeight: 36
                        enabled: !root.lezBusy
                        model: [
                            {
                                t: "Private",
                                pub: false
                            },
                            {
                                t: "Public",
                                pub: true
                            }
                        ]
                        textRole: "t"
                        valueRole: "pub"
                    }
                }

                // AMOUNT + send
                RowLayout {
                    Layout.fillWidth: true
                    spacing: Theme.spacing.small
                    FormLabel {
                        text: "Amount"
                    }
                    LogosTextField {
                        id: xferAmtField
                        Layout.preferredWidth: 130
                        placeholderText: "0"
                        enabled: !root.lezBusy
                        Component.onCompleted: textInput.validator = intValidator
                    }
                    LogosText {
                        text: "of " + root.fmt(sendCard.fromBal)
                        color: Theme.palette.textTertiary
                        font.pixelSize: Theme.typography.secondaryText
                    }
                    Item {
                        Layout.fillWidth: true
                    }
                    ActionButton {
                        accent: true
                        text: root.lezBusy ? "Sending…" : "Send"
                        enabled: !root.lezBusy && sendCard.fromAcct && root.validRecipient(xferToField.text, destTypeBox.currentValue) && Number(xferAmtField.text) > 0 && !sendCard.amtOver
                        onClicked: {
                            var f = sendCard.fromAcct;
                            var destPub = destTypeBox.currentValue;
                            var kind = root.xferKind(!!f.isPublic, destPub);
                            root.lezTransfer(kind, f.id, root.recipientArg(xferToField.text, destPub), xferAmtField.text.trim());
                        }
                    }
                }

                // Who-can-see-this preview, in plain words
                NoticeBanner {
                    visible: sendCard.fromAcct !== null
                    tint: {
                        var f = sendCard.fromAcct;
                        if (!f)
                            return Theme.palette.info;
                        var k = root.xferKind(!!f.isPublic, destTypeBox.currentValue);
                        return (k === "private") ? Theme.palette.primary : Theme.palette.info;
                    }
                    text: {
                        var f = sendCard.fromAcct;
                        if (!f)
                            return "";
                        var k = root.xferKind(!!f.isPublic, destTypeBox.currentValue);
                        if (k === "private")
                            return "Private transfer — completely hidden. Nobody but you and the recipient can see it, not even the amount.";
                        if (k === "shielded")
                            return "This shields the tokens: they leave your public balance and arrive as private, hidden from everyone.";
                        if (k === "deshielded")
                            return "Heads up — this deshields the tokens: they leave your private balance and become publicly visible.";
                        return "Public transfer — anyone can look up the amount and both accounts on-chain.";
                    }
                }
                LogosText {
                    visible: sendCard.amtOver && Number(xferAmtField.text) > 0
                    text: "That's more than this account has — try a smaller amount."
                    color: Theme.palette.warning
                    font.pixelSize: 11
                }
                LogosText {
                    visible: xferToField.text.trim().length > 0 && !root.validRecipient(xferToField.text, destTypeBox.currentValue)
                    text: destTypeBox.currentValue ? "That doesn't look like a valid account id — double-check what you pasted." : "For a private recipient you need their receiving address — it starts with “lezpriv1”. Ask them to press “Receive” on their private account and send it to you."
                    Layout.fillWidth: true
                    wrapMode: Text.Wrap
                    color: Theme.palette.warning
                    font.pixelSize: 11
                }
                // Clear the fields on a successful send. This lives inside the
                // tab Component so it can see xferToField (the root-level event
                // handler cannot — the ids are scoped to this Component).
                Connections {
                    target: (typeof logos !== "undefined") ? logos : null
                    function onModuleEventReceived(m, e, d) {
                        if (m !== "persona_core" || e !== "lezTransferFinished")
                            return;
                        var rr;
                        try {
                            rr = JSON.parse(d[0]);
                        } catch (x) {
                            rr = null;
                        }
                        if (rr && rr.ok) {
                            xferToField.text = "";
                            xferAmtField.text = "";
                        }
                    }
                }
            }

            // bottom half of the vertical centering for the setup cards
            Item {
                visible: !root.lezReady
                Layout.fillHeight: true
            }
        }
    }
}
