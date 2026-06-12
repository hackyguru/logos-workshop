// Lotion (logos + notion) — a Notion-style local-first writing workspace
// on logos-storage.
//
// Model:
//   * Your pages live in a local SQLite workspace (publishing-core). They
//     open instantly, edit inline, and autosave — no network needed.
//   * Publishing is optional and per-page: hit Publish to push a page to
//     logos-storage and get a shareable CID. A page can stay a local draft
//     forever.
//   * Reading: paste a CID to open someone else's article read-only, then
//     optionally duplicate it into your workspace.
//
// IPC rules (learned the hard way — see project memory):
//   * storage_module is driven from QML (C++→storage hangs on macOS).
//   * Every callModule is ASYNC — a sync call from inside an event handler
//     deadlocks the UI thread for ~20s.

import QtQuick 2.15
import QtQuick.Controls 2.15
import QtQuick.Layouts 1.15
import QtQuick.Dialogs

import Logos.Theme 1.0
import Logos.Controls 1.0

Item {
    id: root
    width: 1180
    height: 820

    // ── Workspace state ───────────────────────────────────────────────
    property var    documents: []        // sidebar list
    property int    currentId: -1         // open page id (-1 = none)
    property var    currentDoc: ({})      // open page fields
    property string mode: "empty"         // "empty" | "editor" | "reader"
    property bool   sidebarCollapsed: false
    property bool   coverMenuOpen: false
    // Sidebar nesting: which page ids are expanded to show their children.
    property var    expanded: ({})

    // Editor-local mirrors (so autosave reads consistent values).
    property string editorCover: JSON.stringify({ type: "gradient", name: "default" })
    property string editorIcon: ""           // page emoji ("" = none)
    property bool   pageMenuOpen: false
    property bool   iconPickerOpen: false
    readonly property var iconChoices: [
        "📄","📝","📌","💡","✅","📚","🗂️","📁","🎯","🚀","🔥","⭐","❤️","🎨","🧠","🛠️",
        "📅","💬","🔒","🌍","🏷️","📦","🧪","⚙️","📈","🧩","🎵","☕","🍀","🌙","⚡","🏆"
    ]
    property bool   editorPrivate: false
    // Guard: don't autosave while we're programmatically loading a doc
    // into the fields (setting .text fires textChanged).
    property bool   _loadingDoc: false
    property string _lastListedTitle: ""
    property string _lastListedCover: ""

    // Publish flow: 0 idle, 1 uploading, 2 done, 3 error.
    property var publish: ({ status: 0, cid: "", error: "" })
    property bool publishPanelOpen: false

    // Reader (remote CID) state: 0 idle,1 downloading,2 done,3 error,
    // 4 needs-password,5 decrypting.
    property var lastFetch: ({
        cid: "", title: "", body: "", isPrivate: false,
        status: 0, error: "", destPath: "",
        cover: { type: "gradient", name: "default" }, publishedAt: 0
    })

    // Storage node: 0 Off,1 Starting,2 Online,3 Error. Boots in the
    // background — the workspace never waits on it.
    property int    storageStatus: 0
    property string storageError:  ""
    property bool   initDone: false

    // ── Cover gradients ───────────────────────────────────────────────
    readonly property var gradients: ({
        "default": ["#1c1c1c", "#0e121b"],
        "sunset":  ["#ED7B58", "#DC2626"],
        "ocean":   ["#0284C7", "#00cec9"],
        "forest":  ["#00b894", "#15803D"],
        "violet":  ["#a29bfe", "#fd79a8"],
        "fire":    ["#FB3748", "#F57A02"],
        "ice":     ["#74b9ff", "#dfe6e9"],
        "noir":    ["#2B303B", "#000000"]
    })
    readonly property var gradientNames: [
        "default", "sunset", "ocean", "forest",
        "violet", "fire", "ice", "noir"
    ]
    function gradientColors(name) { return gradients[name] || gradients["default"] }

    // ── Cover helpers ──────────────────────────────────────────────────
    //
    // A cover is stored (in the DB `cover` column, in editorCover, and in
    // lastFetch.cover) as a small object — kept as a JSON string where it
    // needs to live in a string field. Two shapes:
    //   { type:"gradient", name:"sunset" }
    //   { type:"image", cid:"zDv…", localPath:"/…" }  (localPath is local-only)
    // Legacy values (a bare gradient name string, or {gradient:name} from
    // the first envelope format) are normalised to the gradient shape.
    function parseCover(raw) {
        if (!raw) return { type: "gradient", name: "default" }
        var o = raw
        if (typeof raw === "string") {
            try { o = JSON.parse(raw) } catch (e) { return { type: "gradient", name: raw } }
        }
        if (o && o.type) return o
        if (o && o.gradient) return { type: "gradient", name: o.gradient } // legacy envelope
        return { type: "gradient", name: "default" }
    }
    // The plugin's own directory — the ONLY filesystem root Basecamp's QML
    // sandbox lets an Image element load from. Cover images must live here.
    function pluginDir() {
        // Qt.resolvedUrl returns a `url`, not a string — coerce it, or
        // .indexOf throws ("Property 'indexOf' of object … is not a function").
        var u = "" + Qt.resolvedUrl(".")     // file://…/plugins/lotion_ui/
        if (u.indexOf("file://") === 0) u = u.substring(7)
        u = decodeURIComponent(u)
        if (u.charAt(u.length - 1) === "/") u = u.substring(0, u.length - 1)
        return u
    }
    function coversDir() { return pluginDir() + "/covers" }

    function coverIsImage(c)     { return parseCover(c).type === "image" }
    function coverGradient(c)    { var o = parseCover(c); return o.type === "gradient" ? (o.name || "default") : "default" }
    function coverLocalSource(c) { var o = parseCover(c); return o.type === "image" && o.localPath ? normaliseUrl(o.localPath) : "" }
    function gradientStr(name)   { return JSON.stringify({ type: "gradient", name: name }) }

    // Crop focus point (0..1) for image covers — which part of the image
    // stays visible when the wide cover frame crops it. 0.5,0.5 = centre.
    function coverFocusX(c) { var o = parseCover(c); return (typeof o.focusX === "number") ? o.focusX : 0.5 }
    function coverFocusY(c) { var o = parseCover(c); return (typeof o.focusY === "number") ? o.focusY : 0.5 }

    // Set the editor cover's focus point and autosave.
    function setEditorFocus(fx, fy) {
        var o = parseCover(editorCover)
        if (o.type !== "image") return
        o.focusX = Math.max(0, Math.min(1, fx))
        o.focusY = Math.max(0, Math.min(1, fy))
        editorCover = JSON.stringify(o)
        scheduleSave()
    }

    // Compute the source sub-rect that fills `img`'s frame at the given
    // focus point — a precise "cover" crop you can pan (via Image.sourceClipRect).
    function coverClip(img, fx, fy) {
        var iw = img.sourceSize.width, ih = img.sourceSize.height
        if (iw <= 0 || ih <= 0) return Qt.rect(0, 0, 0, 0)   // not loaded yet
        var W = img.width, H = img.height
        if (W <= 0 || H <= 0) return Qt.rect(0, 0, iw, ih)
        var s = Math.max(W / iw, H / ih)        // cover scale
        var srcW = Math.min(iw, W / s)
        var srcH = Math.min(ih, H / s)
        var srcX = (iw - srcW) * fx
        var srcY = (ih - srcH) * fy
        return Qt.rect(srcX, srcY, srcW, srcH)
    }

    // ── Block editor model ────────────────────────────────────────────
    // The document is a list of blocks the user edits IN PLACE (WYSIWYG for
    // structure). It serializes to/from Markdown so storage, copy and
    // publishing stay Markdown. Roles: btype, btext, cells (JSON for tables).
    //   btype ∈ p | h1 | h2 | h3 | bullet | number | quote | code | divider | table
    ListModel { id: blockModel }

    // Index of a block that should grab focus (after insert). -1 = none.
    property int focusBlock: -1
    // Block being drag-reordered (-1 = none). Drag live-moves rows.
    property int draggingBlock: -1
    // Kanban card drag source (set on press).
    property int dragKbCol: -1
    property int dragKbIdx: -1
    // Sidebar page being dragged (for re-parent).
    property int dragPageId: -1

    // Which block sits at editor-content y? (for live block reorder)
    function blockIndexAtY(y) {
        for (var j = 0; j < blockRepeater.count; j++) {
            var it = blockRepeater.itemAt(j)
            if (!it) continue
            var top = it.mapToItem(editorCol, 0, 0).y
            if (y < top + it.height / 2) return j
        }
        return blockRepeater.count - 1
    }
    function kanbanMoveCard(blk, sc, si, dc) {
        var b = kanbanData(blk)
        if (!b[sc] || !b[dc] || si < 0 || si >= b[sc].cards.length) return
        var card = b[sc].cards.splice(si, 1)[0]
        b[dc].cards.push(card)
        _kanbanWrite(blk, b)
    }
    // The block field that currently has focus (for inline B/I) + its index.
    property var activeField: null
    property int activeBlock: -1

    function placeholderFor(bt, index) {
        if (bt === "h1" || bt === "h2" || bt === "h3") return "Heading"
        if (bt === "bullet" || bt === "number") return "List item"
        if (bt === "quote") return "Quote"
        if (bt === "code")  return "Code"
        return "Write something, or press ‘/’ for commands"
    }

    // ── Slash command menu ───────────────────────────────────────────
    property bool   slashOpen: false
    property int    slashBlock: -1
    property string slashQuery: ""
    property int    slashSel: 0
    property real   slashX: 0
    property real   slashY: 0
    readonly property var slashAll: [
        { t: "p",       lbl: "Text",          glyph: "T",   hint: "",    kw: "text paragraph plain body" },
        { t: "h1",      lbl: "Heading 1",     glyph: "H₁",  hint: "#",   kw: "h1 title big heading" },
        { t: "h2",      lbl: "Heading 2",     glyph: "H₂",  hint: "##",  kw: "h2 heading" },
        { t: "h3",      lbl: "Heading 3",     glyph: "H₃",  hint: "###", kw: "h3 heading subheading" },
        { t: "bullet",  lbl: "Bulleted list", glyph: "•",   hint: "-",   kw: "bullet list unordered point dot" },
        { t: "number",  lbl: "Numbered list", glyph: "1.",  hint: "1.",  kw: "number ordered list" },
        { t: "todo",    lbl: "To-do list",    glyph: "☑",   hint: "[]",  kw: "todo to-do checkbox task check done" },
        { t: "toggle",  lbl: "Toggle list",   glyph: "▸",   hint: ">>",  kw: "toggle collapse fold details expand" },
        { t: "callout", lbl: "Callout",       glyph: "💡",  hint: "",    kw: "callout note info tip box highlight" },
        { t: "quote",   lbl: "Quote",         glyph: "❝",   hint: ">",   kw: "quote blockquote" },
        { t: "code",    lbl: "Code",          glyph: "</>", hint: "```", kw: "code monospace snippet" },
        { t: "table",   lbl: "Table",         glyph: "▦",   hint: "",    kw: "table grid rows columns" },
        { t: "kanban",  lbl: "Board",         glyph: "📋",  hint: "",    kw: "kanban board trello columns cards tasks todo" },
        { t: "divider", lbl: "Divider",       glyph: "—",   hint: "---", kw: "divider rule line hr separator" },
        { t: "page",    lbl: "Page",          glyph: "📄",  hint: "",    kw: "page subpage nested document child" }
    ]
    function slashFiltered() {
        var q = slashQuery.toLowerCase()
        if (!q.length) return slashAll
        return slashAll.filter(function(it) {
            return it.lbl.toLowerCase().indexOf(q) !== -1 || it.kw.indexOf(q) !== -1
        })
    }
    function openSlash(blockIndex, field) {
        slashBlock = blockIndex
        slashQuery = ""
        slashSel = 0
        var r = field.positionToRectangle(field.cursorPosition)
        var p = field.mapToItem(root, r.x, r.y + r.height + 4)
        slashX = p.x; slashY = p.y
        slashOpen = true
    }
    function closeSlash() { slashOpen = false; slashBlock = -1; slashQuery = "" }
    function slashMove(d) {
        var n = slashFiltered().length
        if (n > 0) slashSel = (slashSel + d + n) % n
    }
    function acceptSlash() {
        var items = slashFiltered()
        var bi = slashBlock
        if (!items.length || bi < 0) { closeSlash(); return }
        var it = items[Math.max(0, Math.min(slashSel, items.length - 1))]
        closeSlash()
        if (it.t === "page") { createSubPage(bi); return }   // sub-page is special
        setBlockText(bi, "")      // drop the "/query" text
        setBlockType(bi, it.t)
        focusBlock = bi
    }

    // Inline emphasis: wrap the selection in the currently-focused field.
    function fmtWrapField(a, b) {
        var f = activeField
        if (!f) return
        var s = f.selectionStart, e = f.selectionEnd
        if (s === e) { f.insert(s, a + b); f.cursorPosition = s + a.length }
        else {
            var sel = f.text.substring(s, e)
            f.remove(s, e); f.insert(s, a + sel + b)
            f.select(s + a.length, s + a.length + sel.length)
        }
        f.forceActiveFocus()
    }

    function numberFor(index) {
        var n = 1
        for (var k = index - 1; k >= 0; k--) {
            if (blockModel.get(k).btype === "number") n++; else break
        }
        return n
    }

    function defaultCells() { return JSON.stringify([["Column 1","Column 2","Column 3"],["","",""],["","",""]]) }
    function defaultBoard() { return JSON.stringify([{ t: "To do", cards: [] }, { t: "In progress", cards: [] }, { t: "Done", cards: [] }]) }

    function parseMarkdownToBlocks(md) {
        blockModel.clear()
        var lines = (md || "").replace(/\r\n/g, "\n").split("\n")
        var i = 0
        while (i < lines.length) {
            var line = lines[i]
            if (line.trim().match(/^```/)) {
                i++; var code = []
                while (i < lines.length && !lines[i].trim().match(/^```/)) { code.push(lines[i]); i++ }
                i++
                blockModel.append({ btype: "code", btext: code.join("\n"), cells: "" }); continue
            }
            var h = line.match(/^(#{1,6})\s+(.*)$/)
            if (h) {
                var lvl = Math.min(3, h[1].length)
                blockModel.append({ btype: "h" + lvl, btext: h[2], cells: "" }); i++; continue
            }
            if (line.match(/^\s*[-*_]{3,}\s*$/)) { blockModel.append({ btype: "divider", btext: "", cells: "" }); i++; continue }
            if (line.match(/^\s*>/)) {
                var q = []
                while (i < lines.length && lines[i].match(/^\s*>/)) { q.push(lines[i].replace(/^\s*>\s?/, "")); i++ }
                blockModel.append({ btype: "quote", btext: q.join("\n"), cells: "" }); continue
            }
            if (line.indexOf("|") !== -1 && (i + 1) < lines.length && _isTableSep(lines[i + 1])) {
                var rows = [ _splitRow(line) ]; i += 2
                while (i < lines.length && lines[i].indexOf("|") !== -1 && lines[i].trim() !== "") { rows.push(_splitRow(lines[i])); i++ }
                blockModel.append({ btype: "table", btext: "", cells: JSON.stringify(rows) }); continue
            }
            var tdm = line.match(/^\s*[-*+]\s+\[([ xX])\]\s+(.*)$/)
            if (tdm) { blockModel.append({ btype: "todo", btext: tdm[2], cells: (tdm[1].toLowerCase() === "x") ? "1" : "0" }); i++; continue }
            if (line.match(/^\s*[-*+]\s+/)) { blockModel.append({ btype: "bullet", btext: line.replace(/^\s*[-*+]\s+/, ""), cells: "" }); i++; continue }
            if (line.match(/^\s*\d+\.\s+/)) { blockModel.append({ btype: "number", btext: line.replace(/^\s*\d+\.\s+/, ""), cells: "" }); i++; continue }
            var pm = line.match(/^\s*\[[^\]]*\]\(lotion:\/\/page\/(\d+)\)\s*$/)
            if (pm) { blockModel.append({ btype: "page", btext: pm[1], cells: "" }); i++; continue }
            var km = line.match(/^\s*\[[^\]]*\]\(lotion:\/\/kanban\/([A-Za-z0-9+\/=]+)\)\s*$/)
            if (km) { var kj = "[]"; try { kj = Qt.atob(km[1]) } catch (e) {}; blockModel.append({ btype: "kanban", btext: "", cells: kj }); i++; continue }
            var com = line.match(/^\s*\[[^\]]*\]\(lotion:\/\/callout\/([A-Za-z0-9+\/=]+)\)\s*$/)
            if (com) { var cj = {}; try { cj = JSON.parse(Qt.atob(com[1])) } catch (e) {}; blockModel.append({ btype: "callout", btext: cj.text || "", cells: cj.emoji || "💡" }); i++; continue }
            var tgm = line.match(/^\s*\[[^\]]*\]\(lotion:\/\/toggle\/([A-Za-z0-9+\/=]+)\)\s*$/)
            if (tgm) { var tj = {}; try { tj = JSON.parse(Qt.atob(tgm[1])) } catch (e) {}; blockModel.append({ btype: "toggle", btext: tj.title || "", cells: tj.body || "" }); i++; continue }
            if (line.trim() === "") { i++; continue }
            var para = []
            while (i < lines.length && lines[i].trim() !== ""
                   && !lines[i].match(/^#{1,6}\s+/) && !lines[i].trim().match(/^```/)
                   && !lines[i].match(/^\s*>/) && !lines[i].match(/^\s*[-*+]\s+/)
                   && !lines[i].match(/^\s*\d+\.\s+/) && !lines[i].match(/^\s*[-*_]{3,}\s*$/)
                   && !(lines[i].indexOf("|") !== -1 && (i + 1) < lines.length && _isTableSep(lines[i + 1]))) {
                para.push(lines[i]); i++
            }
            blockModel.append({ btype: "p", btext: para.join("\n"), cells: "" })
        }
        if (blockModel.count === 0) blockModel.append({ btype: "p", btext: "", cells: "" })
    }

    function tableToMarkdown(cellsJson) {
        var rows; try { rows = JSON.parse(cellsJson) } catch (e) { rows = [] }
        if (!rows.length) return ""
        var cols = rows[0].length
        var out = "| " + rows[0].join(" | ") + " |\n|"
        for (var c = 0; c < cols; c++) out += " --- |"
        for (var r = 1; r < rows.length; r++) out += "\n| " + rows[r].join(" | ") + " |"
        return out
    }

    function blocksToMarkdown() {
        var parts = []
        for (var i = 0; i < blockModel.count; i++) {
            var b = blockModel.get(i)
            if (b.btype === "divider")      parts.push("---")
            else if (b.btype === "h1")      parts.push("# " + b.btext)
            else if (b.btype === "h2")      parts.push("## " + b.btext)
            else if (b.btype === "h3")      parts.push("### " + b.btext)
            else if (b.btype === "bullet")  parts.push("- " + b.btext)
            else if (b.btype === "number")  parts.push(numberFor(i) + ". " + b.btext)
            else if (b.btype === "todo")    parts.push("- [" + (b.cells === "1" ? "x" : " ") + "] " + b.btext)
            else if (b.btype === "quote")   parts.push(b.btext.split("\n").map(function(l){ return "> " + l }).join("\n"))
            else if (b.btype === "code")    parts.push("```\n" + b.btext + "\n```")
            else if (b.btype === "table")   parts.push(tableToMarkdown(b.cells))
            else if (b.btype === "kanban")  parts.push("[📋 Board](lotion://kanban/" + Qt.btoa(b.cells || "[]") + ")")
            else if (b.btype === "callout") parts.push("[" + (b.cells || "💡") + "](lotion://callout/" + Qt.btoa(JSON.stringify({ emoji: b.cells || "💡", text: b.btext })) + ")")
            else if (b.btype === "toggle")  parts.push("[▸ " + b.btext + "](lotion://toggle/" + Qt.btoa(JSON.stringify({ title: b.btext, body: b.cells })) + ")")
            else if (b.btype === "page")    parts.push("[📄 " + docTitleById(b.btext) + "](lotion://page/" + b.btext + ")")
            else                            parts.push(b.btext)
        }
        var md = ""
        for (var j = 0; j < parts.length; j++) {
            if (j > 0) {
                var prev = blockModel.get(j - 1).btype, cur = blockModel.get(j).btype
                var tight = (prev === cur && (cur === "bullet" || cur === "number" || cur === "todo"))
                md += tight ? "\n" : "\n\n"
            }
            md += parts[j]
        }
        return md
    }

    // ── Block CRUD (each mutation autosaves) ──────────────────────────
    function setBlockText(i, t) { if (i >= 0 && i < blockModel.count) { blockModel.setProperty(i, "btext", t); scheduleSave() } }
    function setBlockCells(i, v) { if (i >= 0 && i < blockModel.count) { blockModel.setProperty(i, "cells", v); scheduleSave() } }
    function toggleTodo(i) { if (i >= 0 && i < blockModel.count) { setBlockCells(i, blockModel.get(i).cells === "1" ? "0" : "1") } }

    readonly property var calloutEmojis: ["💡","📌","⚠️","✅","❤️","🔥","📝","🚀","ℹ️"]
    function cycleCalloutEmoji(i) {
        var cur = blockModel.get(i).cells || "💡"
        var idx = calloutEmojis.indexOf(cur)
        setBlockCells(i, calloutEmojis[(idx + 1) % calloutEmojis.length])
    }

    // Notion-style markdown auto-format: when a paragraph's text becomes a
    // shorthand prefix, convert the block type. Returns {type, rest} or null.
    function autoFormat(t) {
        if (t === "# ")   return { type: "h1",     rest: "" }
        if (t === "## ")  return { type: "h2",     rest: "" }
        if (t === "### ") return { type: "h3",     rest: "" }
        if (t === "- " || t === "* ") return { type: "bullet", rest: "" }
        if (t === "1. ")  return { type: "number", rest: "" }
        if (t === "[] " || t === "[ ] ") return { type: "todo", rest: "" }
        if (t === "> ")   return { type: "quote",  rest: "" }
        if (t === "```")  return { type: "code",   rest: "" }
        return null
    }
    function setBlockType(i, bt) {
        if (i < 0 || i >= blockModel.count) return
        blockModel.setProperty(i, "btype", bt)
        if (bt === "table"   && !blockModel.get(i).cells) blockModel.setProperty(i, "cells", defaultCells())
        if (bt === "kanban"  && !blockModel.get(i).cells) blockModel.setProperty(i, "cells", defaultBoard())
        if (bt === "callout" && !blockModel.get(i).cells) blockModel.setProperty(i, "cells", "💡")
        if (bt === "todo")  blockModel.setProperty(i, "cells", blockModel.get(i).cells === "1" ? "1" : "0")
        scheduleSave()
    }
    function addBlockAfter(i, bt) {
        bt = bt || "p"
        var initCells = bt === "table" ? defaultCells()
                      : bt === "kanban" ? defaultBoard()
                      : bt === "callout" ? "💡"
                      : bt === "todo" ? "0" : ""
        var row = { btype: bt, btext: "", cells: initCells }
        var at = (i < 0) ? blockModel.count : (i + 1)
        blockModel.insert(at, row)
        scheduleSave()
        return at
    }
    function removeBlock(i) {
        if (i < 0 || i >= blockModel.count) return
        if (blockModel.count <= 1) { blockModel.setProperty(0, "btype", "p"); blockModel.setProperty(0, "btext", ""); blockModel.setProperty(0, "cells", "") }
        else blockModel.remove(i)
        scheduleSave()
    }
    // Table cell / structure ops.
    function tableRows(i) { try { return JSON.parse(blockModel.get(i).cells) } catch (e) { return [] } }
    function tableSetCell(i, r, c, v) { var rows = tableRows(i); if (rows[r] !== undefined) { rows[r][c] = v; blockModel.setProperty(i, "cells", JSON.stringify(rows)); scheduleSave() } }
    function tableAddRow(i) { var rows = tableRows(i); var cols = rows[0] ? rows[0].length : 1; var nr = []; for (var c = 0; c < cols; c++) nr.push(""); rows.push(nr); blockModel.setProperty(i, "cells", JSON.stringify(rows)); scheduleSave() }
    function tableAddCol(i) { var rows = tableRows(i); for (var r = 0; r < rows.length; r++) rows[r].push(""); blockModel.setProperty(i, "cells", JSON.stringify(rows)); scheduleSave() }

    // Kanban board. cells = JSON of [ { t, cards: [card] } ] where a card is
    // either a LABEL card { kind:"label", text } or a PAGE card { kind:"page", id }.
    function kanbanData(i) {
        var raw
        try { raw = JSON.parse(blockModel.get(i).cells) } catch (e) { return [] }
        if (!Array.isArray(raw)) return []
        // Normalize cards (legacy: bare number = page, bare string = label).
        for (var c = 0; c < raw.length; c++) {
            if (!raw[c].cards) raw[c].cards = []
            for (var k = 0; k < raw[c].cards.length; k++) {
                var cd = raw[c].cards[k]
                if (typeof cd === "number")      raw[c].cards[k] = { kind: "page", id: cd }
                else if (typeof cd === "string") raw[c].cards[k] = { kind: "label", text: cd }
            }
        }
        return raw
    }
    function _kanbanWrite(i, b) { blockModel.setProperty(i, "cells", JSON.stringify(b)); scheduleSave() }
    function kanbanAddColumn(i)        { var b = kanbanData(i); b.push({ t: "New column", cards: [] }); _kanbanWrite(i, b) }
    function kanbanDeleteColumn(i, c)  { var b = kanbanData(i); if (c >= 0 && c < b.length) { b.splice(c, 1); _kanbanWrite(i, b) } }
    function kanbanSetColTitle(i, c, v){ var b = kanbanData(i); if (b[c]) { b[c].t = v; _kanbanWrite(i, b) } }
    function kanbanAddLabel(i, c)       { var b = kanbanData(i); if (b[c]) { b[c].cards.push({ kind: "label", text: "" }); _kanbanWrite(i, b) } }
    function kanbanPushPageCard(i, c, id) { var b = kanbanData(i); if (b[c]) { b[c].cards.push({ kind: "page", id: id }); _kanbanWrite(i, b) } }
    function kanbanRemoveCardAt(i, c, k) { var b = kanbanData(i); if (b[c] && b[c].cards) { b[c].cards.splice(k, 1); _kanbanWrite(i, b) } }
    function kanbanSetCardText(i, c, k, v) { var b = kanbanData(i); if (b[c] && b[c].cards[k]) { b[c].cards[k].text = v; _kanbanWrite(i, b) } }
    function kanbanPromoteToPage(i, c, k, id) { var b = kanbanData(i); if (b[c] && b[c].cards[k]) { b[c].cards[k] = { kind: "page", id: id }; _kanbanWrite(i, b) } }

    // Cover image render path in the reader (downloaded from its CID).
    property string coverImagePath: ""
    property string _coverDest: ""
    property string _dlPhase: ""   // "article" | "cover"

    // Publish phasing — an image cover means two sequential uploads
    // (image bytes → CID, then the article envelope referencing it).
    property string _pubPhase: ""  // "" | "image" | "envelope"
    property string _pubTitle: ""
    property string _pubBody: ""
    property string _pubPw: ""
    property var    _pubCover: ({})

    // ── Bridge helpers ────────────────────────────────────────────────
    function callModAsync(moduleId, method, args, cb) {
        if (typeof logos === "undefined" || !logos.callModuleAsync) return
        logos.callModuleAsync(moduleId, method, args, cb || function(){})
    }
    function unwrap(raw, defaultVal) {
        if (raw === null || raw === undefined) return defaultVal
        if (typeof raw !== "string") return raw
        try {
            const inner = JSON.parse(raw)
            if (typeof inner === "string") {
                try { return JSON.parse(inner) } catch (e2) { return inner }
            }
            return inner
        } catch (e) { return defaultVal }
    }
    function unwrapStr(raw) {
        const v = unwrap(raw, "")
        return (typeof v === "string") ? v : String(v || "")
    }
    function unwrapInt(raw, dflt) {
        const v = unwrap(raw, dflt)
        const n = parseInt(v, 10)
        return isNaN(n) ? dflt : n
    }
    function interpretBoolResult(raw) {
        const r = unwrap(raw, null)
        if (r === true)  return true
        if (r === false) return false
        if (r && r.success === true) return true
        return false
    }

    // ── Display helpers ───────────────────────────────────────────────
    function shortCid(cid) {
        if (!cid) return ""
        if (cid.length <= 18) return cid
        return cid.substring(0, 10) + "…" + cid.substring(cid.length - 6)
    }
    function relativeTime(secs) {
        if (!secs) return ""
        const diff = Math.floor(Date.now() / 1000) - secs
        if (diff < 5)     return "just now"
        if (diff < 60)    return diff + "s ago"
        if (diff < 3600)  return Math.floor(diff / 60)   + "m ago"
        if (diff < 86400) return Math.floor(diff / 3600) + "h ago"
        return Math.floor(diff / 86400) + "d ago"
    }
    function normaliseUrl(p) {
        if (!p) return ""
        if (p.indexOf("file://") === 0) return p
        if (p.charAt(0) === "/")        return "file://" + p
        return p
    }
    function titleOf(t) { return (t && t.trim().length) ? t : "Untitled" }

    // ── Markdown → styled HTML (reader render) ────────────────────────
    readonly property string _mdStylesheet:
        "<style type=\"text/css\">"
        + "body { color: #ffffff; }"
        + "h1 { color: #ffffff; font-size: 30px; font-weight: 700; }"
        + "h2 { color: #ffffff; font-size: 24px; font-weight: 700; }"
        + "h3 { color: #ffffff; font-size: 19px; font-weight: 600; }"
        + "h4 { color: #ffffff; font-size: 17px; font-weight: 600; }"
        + "h5 { color: #ffffff; font-size: 15px; font-weight: 600; }"
        + "h6 { color: #a4a4a4; font-size: 14px; font-weight: 600; }"
        + "p  { color: #ffffff; }"
        + "a  { color: #ed7b58; text-decoration: underline; }"
        + "code { font-family: 'Menlo','SF Mono',monospace; background-color: #262626; color: #ffffff; }"
        + "pre  { font-family: 'Menlo','SF Mono',monospace; background-color: #0e121b; color: #ffffff; padding: 12px; }"
        + "blockquote { color: #a4a4a4; border-left: 3px solid #5c5c5c; padding-left: 12px; }"
        + "hr { border: none; height: 1px; background-color: #2b303b; }"
        + "ul, ol { padding-left: 22px; }"
        + "li { color: #ffffff; }"
        + "strong { font-weight: 700; }"
        + "em { font-style: italic; }"
        + "s  { text-decoration: line-through; color: #969696; }"
        + "table { border-collapse: collapse; }"
        + "th { background-color: #262626; color: #ffffff; }"
        + "th, td { border: 1px solid #2b303b; padding: 6px; }"
        + "</style>"

    function _escHtml(s) {
        return String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
    }

    // GFM table helpers.
    function _isTableSep(l) {
        return l.indexOf("|") !== -1 && l.indexOf("-") !== -1 && /^[\s|:-]*$/.test(l)
    }
    function _splitRow(l) {
        var t = l.trim()
        if (t.charAt(0) === "|") t = t.slice(1)
        if (t.charAt(t.length - 1) === "|") t = t.slice(0, -1)
        return t.split("|").map(function(c) { return c.trim() })
    }
    function _mdInline(s) {
        s = _escHtml(s)
        s = s.replace(/`([^`]+)`/g, "<code>$1</code>")
        s = s.replace(/!\[([^\]]*)\]\(([^)]+)\)/g, "<em>[image: $1]</em>")
        s = s.replace(/\[([^\]]+)\]\(([^)]+)\)/g, "<a href=\"$2\">$1</a>")
        s = s.replace(/\*\*([^*]+)\*\*/g, "<strong>$1</strong>")
        s = s.replace(/__([^_]+)__/g, "<strong>$1</strong>")
        s = s.replace(/(^|[^*])\*([^*\n]+)\*/g, "$1<em>$2</em>")
        s = s.replace(/(^|[^_])_([^_\n]+)_/g, "$1<em>$2</em>")
        s = s.replace(/~~([^~]+)~~/g, "<s>$1</s>")
        return s
    }
    function mdToHtml(md) {
        if (!md) return _mdStylesheet + "<p></p>"
        const lines = md.replace(/\r\n/g, "\n").split("\n")
        const out = [_mdStylesheet]
        let i = 0
        while (i < lines.length) {
            const line = lines[i]
            if (line.trim().match(/^```/)) {
                i++
                const codeLines = []
                while (i < lines.length && !lines[i].trim().match(/^```/)) { codeLines.push(lines[i]); i++ }
                i++
                out.push("<pre>" + _escHtml(codeLines.join("\n")) + "</pre>")
                continue
            }
            const h = line.match(/^(#{1,6})\s+(.*)$/)
            if (h) { out.push("<h" + h[1].length + ">" + _mdInline(h[2]) + "</h" + h[1].length + ">"); i++; continue }
            if (line.match(/^\s*[-*_]{3,}\s*$/)) { out.push("<hr/>"); i++; continue }
            if (line.match(/^\s*>/)) {
                const buf = []
                while (i < lines.length && lines[i].match(/^\s*>/)) { buf.push(lines[i].replace(/^\s*>\s?/, "")); i++ }
                out.push("<blockquote>" + _mdInline(buf.join(" ")) + "</blockquote>")
                continue
            }
            if (line.match(/^\s*[-*+]\s+/)) {
                const items = []
                while (i < lines.length && lines[i].match(/^\s*[-*+]\s+/)) { items.push(lines[i].replace(/^\s*[-*+]\s+/, "")); i++ }
                out.push("<ul>" + items.map(function(it){ return "<li>" + _mdInline(it) + "</li>" }).join("") + "</ul>")
                continue
            }
            if (line.match(/^\s*\d+\.\s+/)) {
                const items = []
                while (i < lines.length && lines[i].match(/^\s*\d+\.\s+/)) { items.push(lines[i].replace(/^\s*\d+\.\s+/, "")); i++ }
                out.push("<ol>" + items.map(function(it){ return "<li>" + _mdInline(it) + "</li>" }).join("") + "</ol>")
                continue
            }
            // GFM table: a row with | followed by a |---|---| separator.
            if (line.indexOf("|") !== -1 && (i + 1) < lines.length && _isTableSep(lines[i + 1])) {
                const headers = _splitRow(line)
                i += 2
                let rowsHtml = ""
                while (i < lines.length && lines[i].indexOf("|") !== -1 && lines[i].trim() !== "") {
                    const cells = _splitRow(lines[i])
                    let tds = ""
                    for (let ci = 0; ci < headers.length; ci++)
                        tds += "<td>" + _mdInline(cells[ci] !== undefined ? cells[ci] : "") + "</td>"
                    rowsHtml += "<tr>" + tds + "</tr>"
                    i++
                }
                let ths = ""
                for (let hi = 0; hi < headers.length; hi++) ths += "<th>" + _mdInline(headers[hi]) + "</th>"
                out.push("<table border=\"1\" cellspacing=\"0\" cellpadding=\"6\" width=\"100%\"><tr>"
                         + ths + "</tr>" + rowsHtml + "</table>")
                continue
            }
            if (line.trim() === "") { i++; continue }
            const para = []
            while (i < lines.length && lines[i].trim() !== ""
                   && !lines[i].match(/^(#{1,6})\s+/) && !lines[i].trim().match(/^```/)
                   && !lines[i].match(/^\s*>/) && !lines[i].match(/^\s*[-*+]\s+/)
                   && !lines[i].match(/^\s*\d+\.\s+/) && !lines[i].match(/^\s*[-*_]{3,}\s*$/)
                   && !(lines[i].indexOf("|") !== -1 && (i + 1) < lines.length && _isTableSep(lines[i + 1]))) {
                para.push(lines[i]); i++
            }
            if (para.length) out.push("<p>" + _mdInline(para.join(" ")) + "</p>")
        }
        return out.join("")
    }

    // ── Workspace actions ─────────────────────────────────────────────

    function refreshDocuments() {
        callModAsync("lotion", "listDocuments", [], function(raw) {
            const r = unwrap(raw, [])
            documents = Array.isArray(r) ? r : []
        })
    }

    function newPage() {
        callModAsync("lotion", "createDocument", [], function(raw) {
            const id = unwrapInt(raw, -1)
            if (id < 0) return
            refreshDocuments()
            openDoc(id)
            // Focus the title for an immediate "start typing" feel.
            titleField.forceActiveFocus()
        })
    }

    // Add a child page under `parentId`, expand the parent, open the child.
    function addChildPage(parentId) {
        callModAsync("lotion", "createChildDocument", [String(parentId)], function(raw) {
            const id = unwrapInt(raw, -1)
            if (id < 0) return
            var e = Object.assign({}, expanded); e[parentId] = true; expanded = e
            refreshDocuments()
            openDoc(id)
            titleField.forceActiveFocus()
        })
    }

    // ── Sidebar tree helpers ──────────────────────────────────────────
    function childrenOf(pid) {
        return documents.filter(function(d) {
            return pid === null ? (d.parentId === null || d.parentId === undefined)
                                : (d.parentId === pid)
        })
    }
    function _buildTree(pid, depth, out) {
        var kids = childrenOf(pid)
        for (var i = 0; i < kids.length; i++) {
            var d = kids[i]
            var has = childrenOf(d.id).length > 0
            out.push({ doc: d, depth: depth, hasChildren: has })
            if (has && expanded[d.id]) _buildTree(d.id, depth + 1, out)
        }
        return out
    }
    function treeRows() { return _buildTree(null, 0, []) }
    function toggleExpand(id) {
        var e = Object.assign({}, expanded)
        e[id] = !e[id]
        expanded = e
    }
    function docTitleById(id) {
        var n = parseInt(id, 10)
        for (var i = 0; i < documents.length; i++) if (documents[i].id === n) return titleOf(documents[i].title)
        return "Untitled"
    }
    function _docById(id) {
        var n = parseInt(id, 10)
        for (var i = 0; i < documents.length; i++) if (documents[i].id === n) return documents[i]
        return null
    }
    // Root→current chain for the breadcrumb bar.
    function breadcrumbChain() {
        var chain = []
        var id = currentId, guard = 0
        while (id >= 0 && guard < 50) {
            var d = _docById(id)
            if (!d) break
            chain.unshift({ id: d.id, title: titleOf(d.title), icon: d.icon || "" })
            id = (d.parentId === null || d.parentId === undefined) ? -1 : d.parentId
            guard++
        }
        return chain
    }
    function setPageIcon(emoji) {
        if (currentId < 0) return
        editorIcon = emoji
        iconPickerOpen = false
        callModAsync("lotion", "setIcon", [String(currentId), emoji], function(){ refreshDocuments() })
    }
    function duplicateCurrent() {
        if (currentId < 0) return
        pageMenuOpen = false
        callModAsync("lotion", "duplicateDocument", [String(currentId)], function(raw) {
            var id = unwrapInt(raw, -1)
            if (id < 0) return
            refreshDocuments()
            openDoc(id)
        })
    }
    function copyCurrentMarkdown() {
        pageMenuOpen = false
        var md = (titleField.text.trim().length ? ("# " + titleField.text + "\n\n") : "") + blocksToMarkdown()
        mdClip.text = md
        mdClip.selectAll()
        mdClip.copy()
    }
    // Raw title (may be empty) — for seeding an editable field.
    function docRawTitleById(id) {
        var n = parseInt(id, 10)
        for (var i = 0; i < documents.length; i++) if (documents[i].id === n) return documents[i].title || ""
        return ""
    }

    // Slash "/page": turn the current block into a sub-page link + create
    // the child document, then open it (Notion-style).
    function createSubPage(blockIndex) {
        if (currentId < 0) return
        callModAsync("lotion", "createChildDocument", [String(currentId)], function(raw) {
            var cid = unwrapInt(raw, -1)
            if (cid < 0) return
            blockModel.setProperty(blockIndex, "btype", "page")
            blockModel.setProperty(blockIndex, "btext", String(cid))
            blockModel.setProperty(blockIndex, "cells", "")
            var e = Object.assign({}, expanded); e[currentId] = true; expanded = e
            saveNow()
            refreshDocuments()
            openDoc(cid)
            titleField.forceActiveFocus()
        })
    }

    function openDoc(id) {
        // Flush the page we're leaving BEFORE loading the next one — the
        // 700ms autosave may not have fired yet, and switching pages
        // replaces the editor's blocks. saveNow() captures the current
        // title/blocks/id synchronously, so this saves the right doc.
        if (currentId >= 0 && mode === "editor") saveNow()
        callModAsync("lotion", "getDocument", [String(id)], function(raw) {
            const d = unwrap(raw, null)
            if (!d || d.id === undefined) return
            _loadingDoc = true
            currentDoc    = d
            currentId     = d.id
            editorCover   = d.cover || gradientStr("default")
            editorIcon    = d.icon || ""
            editorPrivate = !!d.isPrivate
            pageMenuOpen  = false
            iconPickerOpen = false
            titleField.text = d.title || ""
            parseMarkdownToBlocks(d.body || "")
            _lastListedTitle = d.title || ""
            _lastListedCover = d.cover || gradientStr("default")
            publish = { status: d.cid ? 2 : 0, cid: d.cid || "", error: "" }
            publishPanelOpen = false
            mode = "editor"
            _loadingDoc = false
        })
    }

    function deleteDoc(id) {
        callModAsync("lotion", "deleteDocument", [String(id)], function() {
            if (id === currentId) { currentId = -1; currentDoc = ({}); mode = "empty" }
            refreshDocuments()
        })
    }

    Timer {
        id: autosaveTimer
        interval: 700
        repeat: false
        onTriggered: saveNow()
    }
    function scheduleSave() {
        if (_loadingDoc || mode !== "editor" || currentId < 0) return
        autosaveTimer.restart()
    }
    function saveNow() {
        if (currentId < 0) return
        const t = titleField.text
        const cov = editorCover
        const b = blocksToMarkdown()
        callModAsync("lotion", "saveDocument",
            [String(currentId), t, b, cov, editorPrivate ? "true" : "false"],
            function() {
                // Refresh the sidebar when the title OR cover changed — those
                // are what the tree row shows. Body-only edits don't refresh
                // (avoids rebuilding the tree on every keystroke).
                if (t !== _lastListedTitle || cov !== _lastListedCover) {
                    _lastListedTitle = t
                    _lastListedCover = cov
                    refreshDocuments()
                }
            })
    }

    // ── Cover image picking (editor) ──────────────────────────────────

    function setImageCover(srcUrl) {
        if (!srcUrl) return
        callModAsync("lotion", "importCoverImage", [String(srcUrl), coversDir()], function(raw) {
            const p = unwrapStr(raw)
            if (!p) { coverError.text = "Couldn't load that image."; return }
            coverError.text = ""
            editorCover = JSON.stringify({ type: "image", localPath: p })
            scheduleSave()
        })
    }

    // ── Publish ───────────────────────────────────────────────────────
    //
    // An image cover needs the image bytes on storage first, so publishing
    // is up to two sequential uploads: (1) the cover image → its CID, then
    // (2) the article envelope referencing that CID. `_pubPhase` tells the
    // storageUploadDone handler which upload just finished.

    function doPublish() {
        if (storageStatus !== 2 || currentId < 0) return
        if (publish.status === 1) return
        saveNow()  // flush latest edits
        const title = titleField.text.trim()
        const body  = blocksToMarkdown()
        if (!title || !body.trim()) { publish = { status: 3, cid: "", error: "Add a title and some content first." }; return }
        const pw = editorPrivate ? publishPassword.text : ""
        if (editorPrivate && pw.length === 0) { publish = { status: 3, cid: "", error: "Enter a password for this private page." }; return }

        _pubTitle = title; _pubBody = body; _pubPw = pw
        _pubCover = parseCover(editorCover)
        publish = { status: 1, cid: "", error: "" }

        if (_pubCover.type === "image" && _pubCover.localPath && !_pubCover.cid) {
            // Phase 1 — upload the cover image bytes. CID arrives via the event.
            _pubPhase = "image"
            callModAsync("storage_module", "uploadUrl",
                [normaliseUrl(_pubCover.localPath)], function() {})
        } else {
            startEnvelopeUpload()
        }
    }

    function startEnvelopeUpload() {
        _pubPhase = "envelope"
        const coverMeta = _pubCover.type === "image"
            ? { type: "image", cid: _pubCover.cid,
                focusX: (typeof _pubCover.focusX === "number") ? _pubCover.focusX : 0.5,
                focusY: (typeof _pubCover.focusY === "number") ? _pubCover.focusY : 0.5 }
            : { type: "gradient", name: _pubCover.name || "default" }
        const meta = JSON.stringify({
            publishedAt: Math.floor(Date.now() / 1000),
            cover: coverMeta
        })
        callModAsync("lotion", "prepareEnvelopeFile",
            [_pubTitle, _pubBody, _pubPw, meta], function(raw) {
                const path = unwrapStr(raw)
                if (!path) { publish = { status: 3, cid: "", error: "Couldn't build the envelope." }; _pubPhase = ""; return }
                callModAsync("storage_module", "uploadUrl", [normaliseUrl(path)], function() {})
            })
    }

    // ── Reader (remote CID) ───────────────────────────────────────────

    function openByCid(cidArg) {
        const cid = (cidArg || cidInput.text).trim()
        if (!cid) return
        if (lastFetch.cid === cid && lastFetch.status === 4 && lastFetch.destPath) {
            consumeDownloaded(readerPassword.text); return
        }
        if (lastFetch.cid === cid && (lastFetch.status === 1 || lastFetch.status === 5)) return
        if (currentId >= 0 && mode === "editor") saveNow()   // flush before leaving editor
        mode = "reader"
        currentId = -1
        coverImagePath = ""; _dlPhase = ""
        if (storageStatus !== 2) {
            lastFetch = { cid: cid, title: "", body: "", isPrivate: false,
                          status: 3, error: "Storage is still connecting — try again in a moment.",
                          destPath: "", cover: { type: "gradient", name: "default" }, publishedAt: 0 }
            return
        }
        const dest = "/tmp/lotion-" + cid.substring(0, 12) + "-" + Date.now() + ".env"
        lastFetch = { cid: cid, title: "", body: "", isPrivate: false,
                      status: 1, error: "", destPath: dest,
                      cover: { type: "gradient", name: "default" }, publishedAt: 0 }
        _dlPhase = "article"
        readerPassword.text = ""
        callModAsync("storage_module", "downloadToUrl", [cid, normaliseUrl(dest), false], function() {})
    }

    function consumeDownloaded(pw) {
        const path = lastFetch.destPath
        if (!path) return
        callModAsync("lotion", "consumeEnvelopeFile", [path, pw], function(raw) {
            const out = unwrap(raw, null)
            if (!out) { lastFetch = Object.assign({}, lastFetch, { status: 3, error: "No result from decrypt." }); return }
            if (out.ok) {
                const cov = parseCover(out.cover)
                lastFetch = Object.assign({}, lastFetch, {
                    title: out.title || "", body: out.body || "",
                    isPrivate: !!out.isPrivate, status: 2, error: "",
                    cover: cov, publishedAt: out.publishedAt || 0
                })
                coverImagePath = ""
                // If the cover is an image, fetch its bytes (phase 2) into
                // the plugin's own dir so the sandbox lets an Image load it.
                if (cov.type === "image" && cov.cid && storageStatus === 2) {
                    callModAsync("lotion", "ensureCoversDir", [coversDir()], function(draw) {
                        const dir = unwrapStr(draw) || coversDir()
                        _coverDest = dir + "/cover-" + cov.cid.substring(0, 12) + "-" + Date.now() + ".img"
                        _dlPhase = "cover"
                        callModAsync("storage_module", "downloadToUrl",
                            [cov.cid, normaliseUrl(_coverDest), false], function() {})
                    })
                } else {
                    _dlPhase = ""
                }
            } else if (out.needsPassword) {
                lastFetch = Object.assign({}, lastFetch, { status: 4, error: out.error || "needs password" })
                readerPassword.forceActiveFocus()
            } else {
                lastFetch = Object.assign({}, lastFetch, { status: 3, error: out.error || "parse failed" })
            }
        })
    }

    function duplicateToWorkspace() {
        if (lastFetch.status !== 2) return
        const t = lastFetch.title, b = lastFetch.body
        const priv = lastFetch.isPrivate
        // Carry the cover, but drop any downloaded image (its CID stays in
        // the cover object so it still renders / re-publishes).
        const cov = JSON.stringify(parseCover(lastFetch.cover))
        callModAsync("lotion", "createDocument", [], function(raw) {
            const id = unwrapInt(raw, -1)
            if (id < 0) return
            callModAsync("lotion", "saveDocument",
                [String(id), t, b, cov, priv ? "true" : "false"], function() {
                    refreshDocuments()
                    openDoc(id)
                })
        })
    }

    // ── Events ────────────────────────────────────────────────────────

    Connections {
        target: typeof logos !== "undefined" ? logos : null
        function onModuleEventReceived(moduleName, eventName, data) {
            if (moduleName === "storage_module") handleStorageEvent(eventName, data)
            else if (moduleName === "lotion" && eventName === "documentsChanged") refreshDocuments()
        }
    }

    function handleStorageEvent(eventName, data) {
        if (typeof data === "string") { try { data = JSON.parse(data) } catch (e) {} }
        if (eventName === "storageStart") {
            const ok = data && (data[0] === true || data[0] === "true")
            if (ok) { storageStatus = 2; storageError = "" }
            else    { storageStatus = 3; storageError = (data && data[1]) || "storage failed to start" }
        } else if (eventName === "storageStop") {
            storageStatus = 0
        } else if (eventName === "storageUploadDone") {
            if (publish.status !== 1 || _pubPhase === "") return
            const okUp = data && data[0] === true
            const cid  = okUp ? (data[2] || data[1] || "") : ""

            if (_pubPhase === "image") {
                if (!cid) { publish = { status: 3, cid: "", error: "Cover image upload failed." }; _pubPhase = ""; return }
                // Remember the image CID on the page so re-publishing reuses it,
                // then proceed to the envelope upload. Preserve the crop focus.
                _pubCover = { type: "image", cid: cid, localPath: _pubCover.localPath,
                              focusX: _pubCover.focusX, focusY: _pubCover.focusY }
                editorCover = JSON.stringify(_pubCover)
                saveNow()
                startEnvelopeUpload()
                return
            }
            // _pubPhase === "envelope"
            if (!cid) { publish = { status: 3, cid: "", error: data && data[2] || "upload failed" }; _pubPhase = ""; return }
            publish = { status: 2, cid: cid, error: "" }
            _pubPhase = ""
            if (currentId >= 0) {
                callModAsync("lotion", "markPublished", [String(currentId), cid],
                    function() {
                        currentDoc = Object.assign({}, currentDoc, { cid: cid })
                        refreshDocuments()
                    })
            }
        } else if (eventName === "storageDownloadDone") {
            // Phase 2: the cover image finished downloading.
            if (_dlPhase === "cover") {
                if (data && data[0] !== false) coverImagePath = _coverDest
                _dlPhase = ""
                return
            }
            // Phase 1: the article envelope.
            if (lastFetch.status !== 1) return
            if (data && data[0] === false) {
                lastFetch = Object.assign({}, lastFetch, { status: 3, error: data[2] || data[1] || "download failed" })
                _dlPhase = ""
                return
            }
            lastFetch = Object.assign({}, lastFetch, { status: 5 })
            consumeDownloaded(readerPassword.text)
        }
    }

    function startStorage() {
        if (storageStatus === 1 || storageStatus === 2) return
        storageStatus = 1; storageError = ""
        function doStart() {
            callModAsync("storage_module", "start", [], function(r) {
                if (!interpretBoolResult(r)) { storageStatus = 3; storageError = "storage_module.start() returned false"; return }
                if (storageStatus === 1) storageStatus = 2
            })
        }
        if (initDone) { doStart(); return }
        callModAsync("storage_module", "init", [JSON.stringify({ "log-level": "INFO" })], function(r) {
            if (!interpretBoolResult(r)) { storageStatus = 3; storageError = "storage init failed"; return }
            initDone = true; doStart()
        })
    }

    Component.onCompleted: {
        if (typeof logos !== "undefined" && logos.onModuleEvent) {
            logos.onModuleEvent("storage_module", "storageStart")
            logos.onModuleEvent("storage_module", "storageStop")
            logos.onModuleEvent("storage_module", "storageUploadDone")
            logos.onModuleEvent("storage_module", "storageDownloadDone")
            logos.onModuleEvent("lotion",     "documentsChanged")
        }
        refreshDocuments()
        startStorage()   // background — workspace doesn't wait on it
    }

    // ── Background ────────────────────────────────────────────────────
    Rectangle { anchors.fill: parent; color: Theme.palette.background }

    RowLayout {
        anchors.fill: parent
        spacing: 0

        // ════════ SIDEBAR ════════
        Rectangle {
            Layout.preferredWidth: sidebarCollapsed ? 48 : 280
            Layout.fillHeight: true
            color: Theme.palette.backgroundSecondary
            Behavior on Layout.preferredWidth { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }

            // Right hairline
            Rectangle {
                anchors.right: parent.right; anchors.top: parent.top; anchors.bottom: parent.bottom
                width: 1; color: Theme.palette.borderSubtle
            }

            // ── Collapsed rail ──
            ColumnLayout {
                visible: sidebarCollapsed
                anchors.fill: parent
                anchors.topMargin: Theme.spacing.medium
                anchors.bottomMargin: Theme.spacing.medium
                spacing: Theme.spacing.medium
                Image {
                    source: "icons/lotion.png"
                    sourceSize: Qt.size(40, 40)
                    Layout.preferredWidth: 24; Layout.preferredHeight: 24
                    Layout.alignment: Qt.AlignHCenter
                    fillMode: Image.PreserveAspectFit
                }
                Rectangle {
                    Layout.preferredWidth: 30; Layout.preferredHeight: 30
                    Layout.alignment: Qt.AlignHCenter
                    radius: Theme.spacing.radiusSmall
                    color: expandHover.containsMouse ? Theme.palette.backgroundTertiary : "transparent"
                    LogosText { anchors.centerIn: parent; text: "»"; font.pixelSize: 16; color: Theme.palette.textSecondary }
                    MouseArea { id: expandHover; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: sidebarCollapsed = false }
                }
                Rectangle {
                    Layout.preferredWidth: 30; Layout.preferredHeight: 30
                    Layout.alignment: Qt.AlignHCenter
                    radius: Theme.spacing.radiusSmall
                    color: newRailHover.containsMouse ? Theme.palette.backgroundTertiary : "transparent"
                    LogosText { anchors.centerIn: parent; text: "+"; font.pixelSize: 18; color: Theme.palette.textSecondary }
                    MouseArea { id: newRailHover; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: newPage() }
                }

                Rectangle { Layout.preferredWidth: 24; Layout.preferredHeight: 1; Layout.alignment: Qt.AlignHCenter; color: Theme.palette.borderSubtle }

                // Pages as cover chips — quick jump while collapsed.
                ListView {
                    id: railList
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    model: documents
                    spacing: 8
                    clip: true
                    delegate: Item {
                        width: railList.width
                        height: 26
                        Rectangle {
                            anchors.horizontalCenter: parent.horizontalCenter
                            width: 26; height: 26
                            radius: 5
                            clip: true
                            border.color: modelData.id === currentId ? Theme.palette.primary : "transparent"
                            border.width: modelData.id === currentId ? 2 : 0
                            gradient: Gradient {
                                GradientStop { position: 0.0; color: gradientColors(coverGradient(modelData.cover))[0] }
                                GradientStop { position: 1.0; color: gradientColors(coverGradient(modelData.cover))[1] }
                            }
                            Image {
                                anchors.fill: parent
                                visible: coverIsImage(modelData.cover) && coverLocalSource(modelData.cover) !== ""
                                source: coverLocalSource(modelData.cover)
                                fillMode: Image.PreserveAspectCrop
                            }
                            ToolTip.visible: railChipHover.containsMouse
                            ToolTip.text: titleOf(modelData.title)
                            ToolTip.delay: 300
                            MouseArea {
                                id: railChipHover
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: openDoc(modelData.id)
                            }
                        }
                    }
                }
            }

            ColumnLayout {
                visible: !sidebarCollapsed
                anchors.fill: parent
                anchors.margins: Theme.spacing.medium
                spacing: Theme.spacing.medium

                // Workspace header
                RowLayout {
                    Layout.fillWidth: true
                    spacing: Theme.spacing.small
                    Image {
                        source: "icons/lotion.png"
                        sourceSize: Qt.size(40, 40)
                        Layout.preferredWidth: 22
                        Layout.preferredHeight: 22
                        fillMode: Image.PreserveAspectFit
                    }
                    LogosText {
                        text: "Lotion"
                        font.pixelSize: Theme.typography.subtitleText
                        font.weight: Theme.typography.weightBold
                        color: Theme.palette.text
                        Layout.fillWidth: true
                    }
                    // Collapse button
                    Rectangle {
                        Layout.preferredWidth: 28; Layout.preferredHeight: 28
                        radius: Theme.spacing.radiusSmall
                        color: collapseHover.containsMouse ? Theme.palette.backgroundTertiary : "transparent"
                        LogosText { anchors.centerIn: parent; text: "«"; font.pixelSize: 16; color: Theme.palette.textSecondary }
                        MouseArea { id: collapseHover; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: sidebarCollapsed = true }
                    }
                }

                // New page button
                Rectangle {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 38
                    radius: Theme.spacing.radiusSmall
                    color: newHover.containsMouse ? Theme.palette.backgroundTertiary : "transparent"
                    border.color: Theme.palette.borderSubtle
                    border.width: 1
                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: Theme.spacing.medium
                        spacing: Theme.spacing.small
                        LogosText { text: "+"; font.pixelSize: 18; color: Theme.palette.textSecondary }
                        LogosText {
                            text: "New page"
                            font.pixelSize: Theme.typography.primaryText
                            color: Theme.palette.text
                            Layout.fillWidth: true
                        }
                    }
                    MouseArea {
                        id: newHover
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: newPage()
                    }
                }

                // Open by CID
                RowLayout {
                    Layout.fillWidth: true
                    spacing: Theme.spacing.tiny
                    LogosTextField {
                        id: cidInput
                        Layout.fillWidth: true
                        implicitHeight: 34
                        placeholderText: "Open a CID…"
                        Connections {
                            target: cidInput.textInput
                            function onAccepted() { openByCid() }
                        }
                    }
                    Rectangle {
                        Layout.preferredWidth: 34; Layout.preferredHeight: 34
                        radius: Theme.spacing.radiusSmall
                        color: openHover.containsMouse ? Theme.palette.backgroundTertiary : "transparent"
                        border.color: Theme.palette.borderSubtle; border.width: 1
                        LogosText { anchors.centerIn: parent; text: "→"; color: Theme.palette.textSecondary; font.pixelSize: 15 }
                        MouseArea {
                            id: openHover
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: openByCid()
                        }
                    }
                }

                // Section label — also a drop target to move a page to the top level
                LogosText {
                    text: rootDrop.containsDrag ? "PAGES — drop to move to top level" : "PAGES"
                    font.pixelSize: 10
                    font.weight: Theme.typography.weightBold
                    font.letterSpacing: 0.5
                    color: rootDrop.containsDrag ? Theme.palette.primary : Theme.palette.textTertiary
                    Layout.fillWidth: true
                    Layout.topMargin: Theme.spacing.small
                    DropArea {
                        id: rootDrop
                        anchors.fill: parent; anchors.margins: -6
                        keys: ["page-row"]
                        onDropped: function(drop) {
                            if (root.dragPageId >= 0)
                                callModAsync("lotion", "setParent",
                                    [String(root.dragPageId), ""],
                                    function(){ refreshDocuments() })
                            root.dragPageId = -1
                        }
                    }
                }

                // Page list
                ListView {
                    id: pageList
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    model: treeRows()
                    spacing: 2
                    clip: true

                    delegate: Rectangle {
                        id: pageRow
                        width: pageList.width
                        height: 30
                        radius: Theme.spacing.radiusSmall
                        color: rowDrop.containsDrag ? Theme.palette.backgroundMuted
                               : (modelData.doc.id === currentId
                               ? Theme.palette.backgroundTertiary
                               : (rowHover.containsMouse ? Theme.palette.backgroundMuted : "transparent"))
                        border.color: rowDrop.containsDrag && root.dragPageId !== modelData.doc.id
                                      ? Theme.palette.primary : "transparent"
                        border.width: 1

                        // drop target → nest the dragged page under this one
                        DropArea {
                            id: rowDrop
                            anchors.fill: parent
                            keys: ["page-row"]
                            onDropped: function(drop) {
                                if (root.dragPageId >= 0 && root.dragPageId !== modelData.doc.id) {
                                    var pid = modelData.doc.id
                                    callModAsync("lotion", "setParent",
                                        [String(root.dragPageId), String(pid)],
                                        function(){ var e = Object.assign({}, expanded); e[pid] = true; expanded = e; refreshDocuments() })
                                }
                                root.dragPageId = -1
                            }
                        }

                        RowLayout {
                            anchors.fill: parent
                            anchors.leftMargin: Theme.spacing.small + modelData.depth * 16
                            anchors.rightMargin: Theme.spacing.small
                            spacing: Theme.spacing.tiny

                            // drag handle (hover) → re-parent in the tree
                            LogosText {
                                Layout.preferredWidth: 12
                                text: "⠿"; font.pixelSize: 11
                                opacity: rowHover.containsMouse ? 1 : 0
                                color: pageGrip.pressed ? Theme.palette.text : Theme.palette.textTertiary
                                verticalAlignment: Text.AlignVCenter
                                MouseArea {
                                    id: pageGrip
                                    anchors.fill: parent; anchors.margins: -3
                                    hoverEnabled: true; preventStealing: true
                                    cursorShape: pressed ? Qt.ClosedHandCursor : Qt.OpenHandCursor
                                    property bool dragging: false
                                    onPressed: function(mouse) {
                                        root.dragPageId = modelData.doc.id
                                        var pt = mapToItem(root, mouse.x, mouse.y)
                                        pageDragProxy.x = pt.x + 8; pageDragProxy.y = pt.y + 8
                                        pageDragProxy.label = (modelData.doc.icon ? modelData.doc.icon + " " : "") + titleOf(modelData.doc.title)
                                        pageDragProxy.visible = true
                                        pageDragProxy.Drag.start()
                                        dragging = true
                                    }
                                    onPositionChanged: function(mouse) {
                                        if (!dragging) return
                                        var pt = mapToItem(root, mouse.x, mouse.y)
                                        pageDragProxy.x = pt.x + 8; pageDragProxy.y = pt.y + 8
                                    }
                                    onReleased: {
                                        if (dragging) { pageDragProxy.Drag.drop(); pageDragProxy.visible = false; dragging = false }
                                        root.dragPageId = -1
                                    }
                                }
                            }

                            // Disclosure chevron (only if it has children)
                            LogosText {
                                Layout.preferredWidth: 12
                                text: modelData.hasChildren ? (expanded[modelData.doc.id] ? "▼" : "▶") : ""
                                color: discHover.containsMouse ? Theme.palette.text : Theme.palette.textTertiary
                                font.pixelSize: 9
                                horizontalAlignment: Text.AlignHCenter
                                verticalAlignment: Text.AlignVCenter
                                MouseArea {
                                    id: discHover
                                    anchors.fill: parent; anchors.margins: -4
                                    enabled: modelData.hasChildren
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: toggleExpand(modelData.doc.id)
                                }
                            }

                            // Cover chip (small square — keeps rows compact)
                            Rectangle {
                                Layout.preferredWidth: 16
                                Layout.preferredHeight: 16
                                Layout.alignment: Qt.AlignVCenter
                                radius: 4
                                clip: true
                                gradient: Gradient {
                                    GradientStop { position: 0.0; color: gradientColors(coverGradient(modelData.doc.cover))[0] }
                                    GradientStop { position: 1.0; color: gradientColors(coverGradient(modelData.doc.cover))[1] }
                                }
                                Image {
                                    anchors.fill: parent
                                    visible: coverIsImage(modelData.doc.cover) && coverLocalSource(modelData.doc.cover) !== ""
                                    source: coverLocalSource(modelData.doc.cover)
                                    fillMode: Image.PreserveAspectCrop
                                }
                            }

                            LogosText {
                                Layout.fillWidth: true
                                Layout.leftMargin: 2
                                text: (modelData.doc.icon ? modelData.doc.icon + "  " : "") + titleOf(modelData.doc.title)
                                font.pixelSize: Theme.typography.primaryText
                                font.weight: Theme.typography.weightMedium
                                color: Theme.palette.text
                                elide: Text.ElideRight
                                verticalAlignment: Text.AlignVCenter
                            }
                            LogosText { visible: modelData.doc.isPrivate; text: "🔒"; font.pixelSize: 10 }

                            // Add sub-page (hover)
                            LogosText {
                                visible: rowHover.containsMouse
                                Layout.preferredWidth: 16
                                text: "+"; font.pixelSize: 16
                                color: addChildHover.containsMouse ? Theme.palette.text : Theme.palette.textTertiary
                                ToolTip.visible: addChildHover.containsMouse; ToolTip.text: "Add a page inside"; ToolTip.delay: 350
                                MouseArea {
                                    id: addChildHover
                                    anchors.fill: parent; anchors.margins: -4
                                    hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                    onClicked: addChildPage(modelData.doc.id)
                                }
                            }
                            // Delete (hover)
                            LogosText {
                                visible: rowHover.containsMouse
                                Layout.preferredWidth: 14
                                text: "×"; font.pixelSize: 16
                                color: delHover.containsMouse ? Theme.palette.error : Theme.palette.textTertiary
                                MouseArea {
                                    id: delHover
                                    anchors.fill: parent; anchors.margins: -4
                                    hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                    onClicked: deleteDoc(modelData.doc.id)
                                }
                            }
                        }

                        MouseArea {
                            id: rowHover
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: openDoc(modelData.doc.id)
                            z: -1
                        }
                    }

                    LogosText {
                        anchors.centerIn: parent
                        width: parent.width - 20
                        visible: documents.length === 0
                        text: "No pages yet.\nHit “New page” to start writing."
                        horizontalAlignment: Text.AlignHCenter
                        color: Theme.palette.textTertiary
                        font.pixelSize: Theme.typography.secondaryText
                        wrapMode: Text.WordWrap
                    }
                }

                // Storage status footer — subtle.
                RowLayout {
                    Layout.fillWidth: true
                    spacing: Theme.spacing.small
                    Rectangle {
                        width: 7; height: 7; radius: 3.5
                        color: storageStatus === 2 ? Theme.palette.success
                             : storageStatus === 3 ? Theme.palette.error
                             : Theme.palette.warning
                    }
                    LogosText {
                        text: storageStatus === 2 ? "Storage online"
                            : storageStatus === 3 ? "Storage offline"
                            : "Connecting…"
                        font.pixelSize: Theme.typography.secondaryText
                        color: Theme.palette.textTertiary
                        Layout.fillWidth: true
                    }
                    LogosText {
                        visible: storageStatus === 3
                        text: "Retry"
                        font.pixelSize: Theme.typography.secondaryText
                        color: Theme.palette.primary
                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: { storageStatus = 0; startStorage() }
                        }
                    }
                }
            }
        }

        // ════════ MAIN PANE ════════
        Item {
            Layout.fillWidth: true
            Layout.fillHeight: true

            // ─── EMPTY ───
            ColumnLayout {
                anchors.centerIn: parent
                spacing: Theme.spacing.medium
                visible: mode === "empty"
                Image {
                    source: "icons/lotion.png"
                    sourceSize: Qt.size(120, 120)
                    Layout.preferredWidth: 60
                    Layout.preferredHeight: 60
                    Layout.alignment: Qt.AlignHCenter
                    opacity: 0.5
                    fillMode: Image.PreserveAspectFit
                }
                LogosText {
                    Layout.alignment: Qt.AlignHCenter
                    text: "Your workspace"
                    font.pixelSize: Theme.typography.subtitleText
                    font.weight: Theme.typography.weightBold
                    color: Theme.palette.text
                }
                LogosText {
                    Layout.alignment: Qt.AlignHCenter
                    text: "Select a page on the left, or create a new one."
                    color: Theme.palette.textTertiary
                    font.pixelSize: Theme.typography.secondaryText
                }
                LogosButton {
                    Layout.alignment: Qt.AlignHCenter
                    text: "New page"
                    implicitWidth: 130; implicitHeight: 38
                    onClicked: newPage()
                }
            }

            // ─── EDITOR ───
            Item {
                anchors.fill: parent
                visible: mode === "editor"

                // Editor top bar
                Rectangle {
                    id: editorBar
                    anchors.top: parent.top; anchors.left: parent.left; anchors.right: parent.right
                    height: 52
                    color: Theme.palette.background
                    Rectangle {
                        anchors.bottom: parent.bottom; anchors.left: parent.left; anchors.right: parent.right
                        height: 1; color: Theme.palette.borderSubtle
                    }
                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: Theme.spacing.xlarge
                        anchors.rightMargin: Theme.spacing.xlarge
                        spacing: Theme.spacing.small

                        // Breadcrumbs (root → current)
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 4
                            Repeater {
                                model: breadcrumbChain()
                                delegate: RowLayout {
                                    spacing: 4
                                    LogosText {
                                        visible: index > 0
                                        text: "›"; color: Theme.palette.textTertiary; font.pixelSize: Theme.typography.secondaryText
                                    }
                                    LogosText {
                                        text: (modelData.icon ? modelData.icon + " " : "") + modelData.title
                                        elide: Text.ElideRight
                                        Layout.maximumWidth: 200
                                        font.pixelSize: Theme.typography.secondaryText
                                        font.weight: index === breadcrumbChain().length - 1 ? Theme.typography.weightBold : Theme.typography.weightRegular
                                        color: crumbHover.containsMouse ? Theme.palette.text
                                             : (index === breadcrumbChain().length - 1 ? Theme.palette.text : Theme.palette.textTertiary)
                                        MouseArea { id: crumbHover; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: openDoc(modelData.id) }
                                    }
                                }
                            }
                            Item { Layout.fillWidth: true }
                        }

                        LogosText {
                            text: autosaveTimer.running ? "Saving…" : "Saved"
                            font.pixelSize: Theme.typography.secondaryText
                            color: Theme.palette.textTertiary
                        }

                        // Published chip
                        RowLayout {
                            visible: !!publish.cid
                            spacing: Theme.spacing.tiny
                            Rectangle { width: 6; height: 6; radius: 3; color: Theme.palette.success }
                            LogosText { text: "Live"; font.pixelSize: Theme.typography.secondaryText; color: Theme.palette.success }
                        }

                        // Page menu (⋯)
                        Rectangle {
                            Layout.preferredWidth: 30; Layout.preferredHeight: 30
                            radius: Theme.spacing.radiusSmall
                            color: pageMenuHover.containsMouse ? Theme.palette.backgroundTertiary : "transparent"
                            LogosText { anchors.centerIn: parent; text: "⋯"; font.pixelSize: 18; color: Theme.palette.textSecondary }
                            MouseArea { id: pageMenuHover; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: pageMenuOpen = !pageMenuOpen }
                        }

                        LogosButton {
                            text: publish.cid ? "Published ▾" : "Publish ▾"
                            implicitWidth: 130; implicitHeight: 36
                            onClicked: publishPanelOpen = !publishPanelOpen
                        }
                    }
                    TextEdit { id: mdClip; visible: false }
                }

                // Editor scroll body
                LogosScrollView {
                    id: editorScroll
                    anchors.top: editorBar.bottom; anchors.bottom: parent.bottom
                    anchors.left: parent.left; anchors.right: parent.right

                    Item {
                        width: editorScroll.width
                        implicitHeight: coverFull.height + editorCol.implicitHeight
                                        + Theme.spacing.xlarge + Theme.spacing.xxlarge

                        // ── Full-bleed cover banner (spans the whole pane) ──
                        Rectangle {
                            id: coverFull
                            anchors.top: parent.top
                            anchors.left: parent.left
                            anchors.right: parent.right
                            height: 220
                            clip: true
                            gradient: Gradient {
                                GradientStop { position: 0.0; color: gradientColors(coverGradient(editorCover))[0] }
                                GradientStop { position: 1.0; color: gradientColors(coverGradient(editorCover))[1] }
                            }

                            HoverHandler { id: cfHover }

                            Image {
                                id: editorCoverImg
                                anchors.fill: parent
                                visible: coverIsImage(editorCover) && coverLocalSource(editorCover) !== ""
                                source: coverLocalSource(editorCover)
                                fillMode: Image.Stretch
                                sourceClipRect: coverClip(editorCoverImg, coverFocusX(editorCover), coverFocusY(editorCover))
                            }

                            LogosText {
                                anchors.centerIn: parent
                                visible: !coverIsImage(editorCover)
                                text: coverDrop.containsDrag ? "Drop to set cover" : "Add a cover"
                                color: "#ffffff"; opacity: 0.85
                                font.pixelSize: Theme.typography.secondaryText
                            }

                            // Click an empty cover → open the cover picker.
                            MouseArea {
                                anchors.fill: parent
                                visible: !coverIsImage(editorCover)
                                cursorShape: Qt.PointingHandCursor
                                onClicked: coverMenuOpen = true
                            }

                            // Drag the image to reposition the crop.
                            MouseArea {
                                id: coverPan
                                anchors.fill: parent
                                visible: coverIsImage(editorCover)
                                enabled: coverIsImage(editorCover)
                                cursorShape: Qt.SizeAllCursor
                                z: 1
                                property real _sx: 0
                                property real _sy: 0
                                property real _sfx: 0.5
                                property real _sfy: 0.5
                                onPressed: (m) => { _sx = m.x; _sy = m.y; _sfx = coverFocusX(editorCover); _sfy = coverFocusY(editorCover) }
                                onPositionChanged: (m) => {
                                    var dfx = (m.x - _sx) / Math.max(1, width)
                                    var dfy = (m.y - _sy) / Math.max(1, height)
                                    setEditorFocus(_sfx - dfx, _sfy - dfy)
                                }
                            }

                            Rectangle {  // "Drag to reposition" hint
                                visible: coverIsImage(editorCover)
                                anchors.bottom: parent.bottom; anchors.left: parent.left; anchors.margins: Theme.spacing.medium
                                height: 22; width: panHint.implicitWidth + 16; radius: 11
                                color: Qt.rgba(0, 0, 0, 0.5); z: 2
                                LogosText { id: panHint; anchors.centerIn: parent; text: "Drag to reposition"; color: "#ffffff"; font.pixelSize: 11 }
                            }

                            Rectangle {  // remove-image chip
                                visible: coverIsImage(editorCover)
                                anchors.top: parent.top; anchors.right: parent.right; anchors.margins: Theme.spacing.medium
                                width: 26; height: 26; radius: 13; color: Qt.rgba(0, 0, 0, 0.5); z: 3
                                LogosText { anchors.centerIn: parent; text: "×"; color: "#ffffff"; font.pixelSize: 16 }
                                MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: { editorCover = gradientStr("default"); scheduleSave() } }
                            }

                            // "Change cover" pill (appears on hover) → opens picker
                            Rectangle {
                                visible: cfHover.hovered || coverMenuOpen
                                anchors.bottom: parent.bottom; anchors.right: parent.right; anchors.margins: Theme.spacing.medium
                                height: 28; width: ccLbl.implicitWidth + 20; radius: Theme.spacing.radiusSmall
                                color: Qt.rgba(0, 0, 0, 0.55); z: 4
                                LogosText { id: ccLbl; anchors.centerIn: parent; text: "Change cover"; color: "#ffffff"; font.pixelSize: Theme.typography.secondaryText }
                                MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: coverMenuOpen = true }
                            }

                            // Drag-and-drop an image file → set the cover directly.
                            DropArea {
                                id: coverDrop
                                anchors.fill: parent
                                onDropped: (drop) => {
                                    if (drop.hasUrls && drop.urls.length > 0) {
                                        setImageCover(drop.urls[0].toString())
                                        drop.acceptProposedAction()
                                    }
                                }
                            }
                        }

                        FileDialog {
                            id: coverFileDialog
                            title: "Choose a cover image"
                            nameFilters: [ "Images (*.png *.jpg *.jpeg *.gif *.webp *.bmp)" ]
                            onAccepted: setImageCover(selectedFile.toString())
                        }

                        // ── Cover picker popover (gradients + upload) ──
                        MouseArea {
                            anchors.fill: parent
                            visible: coverMenuOpen
                            z: 800
                            onClicked: coverMenuOpen = false
                        }
                        Rectangle {
                            visible: coverMenuOpen
                            z: 801
                            anchors.top: coverFull.bottom
                            anchors.right: coverFull.right
                            anchors.topMargin: 6
                            anchors.rightMargin: Theme.spacing.xlarge
                            width: 280
                            height: cmCol.implicitHeight + 20
                            color: Theme.palette.backgroundSecondary
                            border.color: Theme.palette.borderSubtle; border.width: 1
                            radius: Theme.spacing.radiusLarge
                            ColumnLayout {
                                id: cmCol
                                anchors.fill: parent
                                anchors.margins: 10
                                spacing: Theme.spacing.small
                                LogosText { text: "Color & gradient"; color: Theme.palette.textTertiary; font.pixelSize: 11; font.weight: Theme.typography.weightMedium }
                                GridLayout {
                                    Layout.fillWidth: true
                                    columns: 4
                                    columnSpacing: 8; rowSpacing: 8
                                    Repeater {
                                        model: gradientNames
                                        delegate: Rectangle {
                                            Layout.preferredWidth: 56; Layout.preferredHeight: 38
                                            radius: Theme.spacing.radiusSmall
                                            border.color: (!coverIsImage(editorCover) && coverGradient(editorCover) === modelData) ? Theme.palette.primary : Theme.palette.borderSubtle
                                            border.width: (!coverIsImage(editorCover) && coverGradient(editorCover) === modelData) ? 2 : 1
                                            gradient: Gradient {
                                                GradientStop { position: 0.0; color: gradientColors(modelData)[0] }
                                                GradientStop { position: 1.0; color: gradientColors(modelData)[1] }
                                            }
                                            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: { editorCover = gradientStr(modelData); scheduleSave(); coverMenuOpen = false } }
                                        }
                                    }
                                }
                                Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: Theme.palette.borderSubtle }
                                LogosText { text: "Image"; color: Theme.palette.textTertiary; font.pixelSize: 11; font.weight: Theme.typography.weightMedium }
                                LogosButton {
                                    Layout.fillWidth: true; implicitHeight: 34
                                    text: "Upload an image…"
                                    onClicked: { coverMenuOpen = false; coverFileDialog.open() }
                                }
                                LogosText {
                                    Layout.fillWidth: true
                                    text: "…or drag an image onto the cover."
                                    color: Theme.palette.textTertiary; font.pixelSize: Theme.typography.secondaryText
                                    wrapMode: Text.WordWrap
                                }
                            }
                        }

                        // ── Centered content column ──
                        ColumnLayout {
                            id: editorCol
                            anchors.top: coverFull.bottom
                            anchors.topMargin: Theme.spacing.xlarge
                            anchors.horizontalCenter: parent.horizontalCenter
                            width: Math.min(parent.width - Theme.spacing.xlarge * 2, 720)
                            spacing: Theme.spacing.medium

                            LogosText {
                                id: coverError
                                Layout.fillWidth: true
                                text: ""
                                visible: text.length > 0
                                color: Theme.palette.error
                                font.pixelSize: Theme.typography.secondaryText
                            }

                            // Page icon — big emoji, or "Add icon" on hover.
                            RowLayout {
                                Layout.fillWidth: true
                                spacing: Theme.spacing.small
                                HoverHandler { id: iconRowHover }
                                LogosText {
                                    visible: editorIcon.length > 0
                                    text: editorIcon
                                    font.pixelSize: 46
                                    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: iconPickerOpen = !iconPickerOpen }
                                }
                                LogosText {
                                    visible: editorIcon.length === 0 && iconRowHover.hovered
                                    text: "🙂 Add icon"
                                    color: Theme.palette.textTertiary
                                    font.pixelSize: Theme.typography.secondaryText
                                    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: iconPickerOpen = !iconPickerOpen }
                                }
                                Item { Layout.fillWidth: true }
                            }

                            // Title
                            TextField {
                                id: titleField
                                Layout.fillWidth: true
                                Layout.topMargin: Theme.spacing.small
                                placeholderText: "Untitled"
                                font.family: Theme.typography.publicSans
                                font.pixelSize: Theme.typography.pageTitleText
                                font.weight: Theme.typography.weightBold
                                color: Theme.palette.text
                                placeholderTextColor: Theme.palette.textTertiary
                                selectByMouse: true
                                leftPadding: 0; rightPadding: 0
                                background: Item {}
                                onTextChanged: scheduleSave()
                            }

                            // Divider
                            Rectangle {
                                Layout.fillWidth: true
                                Layout.preferredHeight: 1
                                color: Theme.palette.borderSubtle
                            }

                            // ── Editable blocks (WYSIWYG structure) ──
                            // No top toolbar (Notion-style): add blocks via the
                            // hover "+" handle or by typing "/"; format inline
                            // with ⌘B / ⌘I.
                            Repeater {
                                id: blockRepeater
                                model: blockModel
                                delegate: RowLayout {
                                    Layout.fillWidth: true
                                    Layout.topMargin: 2
                                    spacing: 4
                                    HoverHandler { id: hh }

                                    // left "+" add handle (hover)
                                    LogosText {
                                        Layout.alignment: Qt.AlignTop
                                        Layout.preferredWidth: 16
                                        text: "+"; font.pixelSize: 17
                                        opacity: hh.hovered ? 1 : 0
                                        color: addh.containsMouse ? Theme.palette.text : Theme.palette.textTertiary
                                        ToolTip.visible: addh.containsMouse; ToolTip.text: "Add a block below"; ToolTip.delay: 350
                                        MouseArea {
                                            id: addh; anchors.fill: parent; anchors.margins: -4
                                            hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                            onClicked: root.focusBlock = addBlockAfter(index, "p")
                                        }
                                    }

                                    // drag handle (hover) → reorder blocks; rows reshuffle live
                                    LogosText {
                                        Layout.alignment: Qt.AlignTop
                                        Layout.preferredWidth: 14
                                        text: "⠿"; font.pixelSize: 14
                                        opacity: (hh.hovered || root.draggingBlock === index) ? 1 : 0
                                        color: (gripMA.pressed || gripMA.containsMouse) ? Theme.palette.text : Theme.palette.textTertiary
                                        ToolTip.visible: gripMA.containsMouse && !gripMA.pressed; ToolTip.text: "Drag to move"; ToolTip.delay: 350
                                        MouseArea {
                                            id: gripMA
                                            anchors.fill: parent; anchors.margins: -4
                                            hoverEnabled: true; preventStealing: true
                                            cursorShape: pressed ? Qt.ClosedHandCursor : Qt.OpenHandCursor
                                            onPressed: root.draggingBlock = index
                                            onPositionChanged: function(mouse) {
                                                if (root.draggingBlock < 0) return
                                                var p = mapToItem(editorCol, 0, mouse.y)
                                                var tgt = blockIndexAtY(p.y)
                                                if (tgt >= 0 && tgt !== root.draggingBlock) {
                                                    blockModel.move(root.draggingBlock, tgt, 1)
                                                    root.draggingBlock = tgt
                                                }
                                            }
                                            onReleased: {
                                                if (root.draggingBlock >= 0) scheduleSave()
                                                root.draggingBlock = -1
                                            }
                                        }
                                    }

                                    Loader {
                                        Layout.fillWidth: true
                                        sourceComponent: model.btype === "table" ? tableComp
                                                       : model.btype === "kanban" ? kanbanComp
                                                       : model.btype === "callout" ? calloutComp
                                                       : model.btype === "toggle" ? toggleComp
                                                       : model.btype === "divider" ? dividerComp
                                                       : model.btype === "page" ? pageComp
                                                       : textComp
                                    }

                                    // sub-page link block
                                    Component {
                                        id: pageComp
                                        Rectangle {
                                            implicitHeight: 36
                                            radius: Theme.spacing.radiusSmall
                                            color: pgh.containsMouse ? Theme.palette.backgroundMuted : "transparent"
                                            RowLayout {
                                                anchors.fill: parent
                                                anchors.leftMargin: 4
                                                anchors.rightMargin: 8
                                                spacing: 8
                                                LogosText { text: "📄"; font.pixelSize: 16 }
                                                LogosText {
                                                    Layout.fillWidth: true
                                                    text: docTitleById(model.btext)
                                                    color: Theme.palette.text
                                                    font.pixelSize: Theme.typography.primaryText
                                                    font.underline: true
                                                    elide: Text.ElideRight
                                                }
                                                LogosText { text: "›"; color: Theme.palette.textTertiary; font.pixelSize: 16 }
                                            }
                                            MouseArea {
                                                id: pgh
                                                anchors.fill: parent
                                                hoverEnabled: true
                                                cursorShape: Qt.PointingHandCursor
                                                onClicked: openDoc(parseInt(model.btext, 10))
                                            }
                                        }
                                    }

                                    // callout block (emoji + tinted box)
                                    Component {
                                        id: calloutComp
                                        Rectangle {
                                            implicitHeight: coRow.implicitHeight + 16
                                            radius: Theme.spacing.radiusSmall
                                            color: Qt.rgba(Theme.palette.primary.r, Theme.palette.primary.g, Theme.palette.primary.b, 0.12)
                                            RowLayout {
                                                id: coRow
                                                anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top
                                                anchors.margins: 8
                                                spacing: 8
                                                LogosText {
                                                    Layout.alignment: Qt.AlignTop
                                                    text: (model.cells && model.cells.length) ? model.cells : "💡"
                                                    font.pixelSize: 18
                                                    ToolTip.visible: coEmojiHover.containsMouse; ToolTip.text: "Click to change icon"; ToolTip.delay: 350
                                                    MouseArea { id: coEmojiHover; anchors.fill: parent; anchors.margins: -3; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: cycleCalloutEmoji(index) }
                                                }
                                                TextArea {
                                                    id: coText
                                                    Layout.fillWidth: true
                                                    wrapMode: Text.WordWrap; selectByMouse: true
                                                    color: Theme.palette.text
                                                    font.pixelSize: Theme.typography.primaryText
                                                    placeholderText: "Type something…"
                                                    placeholderTextColor: Theme.palette.textTertiary
                                                    background: null; leftPadding: 0; rightPadding: 0; topPadding: 0; bottomPadding: 0
                                                    Component.onCompleted: { text = model.btext; if (index === root.focusBlock) { forceActiveFocus(); root.focusBlock = -1 } }
                                                    onActiveFocusChanged: if (activeFocus) { root.activeField = coText; root.activeBlock = index }
                                                    onTextChanged: if (text !== model.btext) setBlockText(index, text)
                                                    Keys.onPressed: function(event) {
                                                        if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter) && !(event.modifiers & Qt.ShiftModifier)) {
                                                            event.accepted = true; root.focusBlock = addBlockAfter(index, "p")
                                                        }
                                                    }
                                                }
                                            }
                                        }
                                    }

                                    // toggle list (collapsible title + body)
                                    Component {
                                        id: toggleComp
                                        ColumnLayout {
                                            id: tg
                                            property bool open: true
                                            spacing: 4
                                            RowLayout {
                                                Layout.fillWidth: true
                                                spacing: 6
                                                LogosText {
                                                    Layout.alignment: Qt.AlignTop; Layout.topMargin: 3
                                                    text: tg.open ? "▼" : "▶"
                                                    font.pixelSize: 9; color: Theme.palette.textSecondary
                                                    MouseArea { anchors.fill: parent; anchors.margins: -5; cursorShape: Qt.PointingHandCursor; onClicked: tg.open = !tg.open }
                                                }
                                                TextField {
                                                    id: tgTitle
                                                    Layout.fillWidth: true
                                                    color: Theme.palette.text
                                                    font.weight: Theme.typography.weightMedium
                                                    font.pixelSize: Theme.typography.primaryText
                                                    placeholderText: "Toggle"
                                                    placeholderTextColor: Theme.palette.textTertiary
                                                    background: null; leftPadding: 0; rightPadding: 0
                                                    Component.onCompleted: { text = model.btext; if (index === root.focusBlock) { forceActiveFocus(); root.focusBlock = -1 } }
                                                    onActiveFocusChanged: if (activeFocus) { root.activeField = tgTitle; root.activeBlock = index }
                                                    onTextChanged: if (text !== model.btext) setBlockText(index, text)
                                                }
                                            }
                                            TextArea {
                                                id: tgBody
                                                visible: tg.open
                                                Layout.fillWidth: true
                                                Layout.leftMargin: 18
                                                wrapMode: Text.WordWrap; selectByMouse: true
                                                color: Theme.palette.text
                                                font.pixelSize: Theme.typography.primaryText
                                                placeholderText: "Empty toggle. Type inside…"
                                                placeholderTextColor: Theme.palette.textTertiary
                                                background: null; leftPadding: 0; rightPadding: 0; topPadding: 0; bottomPadding: 0
                                                Component.onCompleted: text = model.cells
                                                onTextChanged: setBlockCells(index, text)
                                            }
                                        }
                                    }

                                    // delete-on-hover
                                    LogosText {
                                        Layout.alignment: Qt.AlignTop
                                        Layout.preferredWidth: 16
                                        text: "×"; font.pixelSize: 16
                                        opacity: hh.hovered ? 1 : 0
                                        color: delh.containsMouse ? Theme.palette.error : Theme.palette.textTertiary
                                        MouseArea { id: delh; anchors.fill: parent; anchors.margins: -4; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: removeBlock(index) }
                                    }

                                    // text-ish block (p / h1-3 / bullet / number / quote / code)
                                    Component {
                                        id: textComp
                                        RowLayout {
                                            spacing: 8
                                            LogosText {
                                                visible: model.btype === "bullet" || model.btype === "number"
                                                Layout.alignment: Qt.AlignTop
                                                Layout.topMargin: 2
                                                text: model.btype === "number" ? (numberFor(index) + ".") : "•"
                                                color: Theme.palette.textSecondary
                                                font.pixelSize: 16
                                            }
                                            // To-do checkbox
                                            Rectangle {
                                                visible: model.btype === "todo"
                                                Layout.alignment: Qt.AlignTop
                                                Layout.topMargin: 3
                                                width: 16; height: 16; radius: 4
                                                color: model.cells === "1" ? Theme.palette.primary : "transparent"
                                                border.color: model.cells === "1" ? Theme.palette.primary : Theme.palette.borderTertiary
                                                border.width: 1
                                                LogosText { anchors.centerIn: parent; visible: model.cells === "1"; text: "✓"; color: "#ffffff"; font.pixelSize: 11 }
                                                MouseArea { anchors.fill: parent; anchors.margins: -3; cursorShape: Qt.PointingHandCursor; onClicked: toggleTodo(index) }
                                            }
                                            Rectangle {
                                                visible: model.btype === "quote"
                                                Layout.preferredWidth: 3
                                                Layout.fillHeight: true
                                                Layout.topMargin: 2; Layout.bottomMargin: 2
                                                color: Theme.palette.borderTertiary
                                            }
                                            TextArea {
                                                id: bf
                                                Layout.fillWidth: true
                                                wrapMode: Text.WordWrap
                                                selectByMouse: true
                                                font.strikeout: model.btype === "todo" && model.cells === "1"
                                                color: (model.btype === "quote" || (model.btype === "todo" && model.cells === "1")) ? Theme.palette.textTertiary : Theme.palette.text
                                                font.family: model.btype === "code" ? "monospace" : Theme.typography.publicSans
                                                font.italic: model.btype === "quote"
                                                font.pixelSize: model.btype === "h1" ? 30 : model.btype === "h2" ? 24 : model.btype === "h3" ? 19 : model.btype === "code" ? 14 : 16
                                                font.weight: (model.btype === "h1" || model.btype === "h2" || model.btype === "h3") ? Theme.typography.weightBold : Theme.typography.weightRegular
                                                // Only the focused empty block shows a hint — otherwise
                                                // the placeholder repeats on every empty block.
                                                placeholderText: (bf.activeFocus || index === 0) ? placeholderFor(model.btype, index) : ""
                                                placeholderTextColor: Theme.palette.textTertiary
                                                leftPadding: model.btype === "code" ? 10 : 0
                                                rightPadding: model.btype === "code" ? 10 : 0
                                                topPadding: model.btype === "code" ? 8 : 2
                                                bottomPadding: model.btype === "code" ? 8 : 2
                                                background: Rectangle {
                                                    visible: model.btype === "code"
                                                    color: Theme.palette.backgroundTertiary
                                                    radius: Theme.spacing.radiusSmall
                                                }
                                                Component.onCompleted: {
                                                    text = model.btext
                                                    if (index === root.focusBlock) { forceActiveFocus(); root.focusBlock = -1 }
                                                }
                                                onActiveFocusChanged: {
                                                    if (activeFocus) { root.activeField = bf; root.activeBlock = index }
                                                    else if (root.slashOpen && root.slashBlock === index) root.closeSlash()
                                                }
                                                onTextChanged: {
                                                    if (text !== model.btext) setBlockText(index, text)
                                                    // Markdown auto-format: a paragraph whose text becomes a
                                                    // shorthand prefix converts to that block type.
                                                    if (model.btype === "p") {
                                                        var af = autoFormat(text)
                                                        if (af) { bf.text = af.rest; setBlockText(index, af.rest); setBlockType(index, af.type); return }
                                                    }
                                                    // Slash menu: "/" at the start of a non-code block.
                                                    if (model.btype !== "code" && text.charAt(0) === "/") {
                                                        if (!root.slashOpen || root.slashBlock !== index) root.openSlash(index, bf)
                                                        root.slashQuery = text.substring(1)
                                                        root.slashSel = 0
                                                    } else if (root.slashOpen && root.slashBlock === index) {
                                                        root.closeSlash()
                                                    }
                                                }
                                                Keys.onPressed: function(event) {
                                                    // Inline emphasis: ⌘B / ⌘I (Cmd = ControlModifier on macOS).
                                                    if ((event.modifiers & Qt.ControlModifier) && (event.key === Qt.Key_B || event.key === Qt.Key_I)) {
                                                        event.accepted = true
                                                        var mk = event.key === Qt.Key_B ? "**" : "*"
                                                        var s = bf.selectionStart, e = bf.selectionEnd
                                                        if (s === e) { bf.insert(s, mk + mk); bf.cursorPosition = s + mk.length }
                                                        else { var sel = bf.text.substring(s, e); bf.remove(s, e); bf.insert(s, mk + sel + mk); bf.select(s + mk.length, s + mk.length + sel.length) }
                                                        return
                                                    }
                                                    // Slash menu navigation takes priority.
                                                    if (root.slashOpen && root.slashBlock === index) {
                                                        if (event.key === Qt.Key_Down)  { root.slashMove(1);  event.accepted = true; return }
                                                        if (event.key === Qt.Key_Up)    { root.slashMove(-1); event.accepted = true; return }
                                                        if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) { root.acceptSlash(); event.accepted = true; return }
                                                        if (event.key === Qt.Key_Escape) { root.closeSlash(); event.accepted = true; return }
                                                    }
                                                    // Enter → new block (Shift+Enter / code = soft newline).
                                                    if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                                                        if ((event.modifiers & Qt.ShiftModifier) || model.btype === "code") return
                                                        event.accepted = true
                                                        var listy = (model.btype === "bullet" || model.btype === "number" || model.btype === "todo")
                                                        if (listy && bf.text.length === 0) { setBlockType(index, "p"); return }
                                                        var nt = listy ? model.btype : "p"
                                                        root.focusBlock = addBlockAfter(index, nt)
                                                        return
                                                    }
                                                    // Backspace at start of an empty block → delete + focus prev.
                                                    if (event.key === Qt.Key_Backspace && bf.text.length === 0 && index > 0) {
                                                        event.accepted = true
                                                        root.focusBlock = index - 1
                                                        removeBlock(index)
                                                    }
                                                }
                                            }
                                        }
                                    }

                                    // divider block
                                    Component {
                                        id: dividerComp
                                        Item {
                                            implicitHeight: 22
                                            Rectangle { anchors.verticalCenter: parent.verticalCenter; width: parent.width; height: 1; color: Theme.palette.borderSubtle }
                                        }
                                    }

                                    // table block — a real editable grid
                                    Component {
                                        id: tableComp
                                        ColumnLayout {
                                            id: tc
                                            spacing: 0
                                            property int blkIndex: index
                                            property var grid: tableRows(index)

                                            Repeater {
                                                model: tc.grid.length
                                                delegate: RowLayout {
                                                    property int rr: index
                                                    Layout.fillWidth: true
                                                    spacing: 0
                                                    Repeater {
                                                        model: tc.grid[rr] ? tc.grid[rr].length : 0
                                                        delegate: Rectangle {
                                                            property int cc: index
                                                            Layout.fillWidth: true
                                                            Layout.preferredHeight: 34
                                                            border.color: Theme.palette.borderSubtle; border.width: 1
                                                            color: rr === 0 ? Theme.palette.backgroundTertiary : "transparent"
                                                            TextField {
                                                                anchors.fill: parent; anchors.margins: 1
                                                                leftPadding: 6; rightPadding: 6
                                                                color: Theme.palette.text
                                                                font.weight: rr === 0 ? Theme.typography.weightBold : Theme.typography.weightRegular
                                                                font.pixelSize: Theme.typography.secondaryText
                                                                placeholderText: rr === 0 ? "Header" : ""
                                                                placeholderTextColor: Theme.palette.textTertiary
                                                                background: null
                                                                Component.onCompleted: text = (tc.grid[rr] && tc.grid[rr][cc] !== undefined) ? tc.grid[rr][cc] : ""
                                                                onTextChanged: {
                                                                    tc.grid[rr][cc] = text
                                                                    blockModel.setProperty(tc.blkIndex, "cells", JSON.stringify(tc.grid))
                                                                    scheduleSave()
                                                                }
                                                            }
                                                        }
                                                    }
                                                }
                                            }
                                            RowLayout {
                                                Layout.topMargin: 4
                                                spacing: 12
                                                LogosText {
                                                    text: "+ Row"; font.pixelSize: Theme.typography.secondaryText; color: Theme.palette.primary
                                                    MouseArea { anchors.fill: parent; anchors.margins: -4; cursorShape: Qt.PointingHandCursor; onClicked: { tableAddRow(tc.blkIndex); tc.grid = tableRows(tc.blkIndex) } }
                                                }
                                                LogosText {
                                                    text: "+ Column"; font.pixelSize: Theme.typography.secondaryText; color: Theme.palette.primary
                                                    MouseArea { anchors.fill: parent; anchors.margins: -4; cursorShape: Qt.PointingHandCursor; onClicked: { tableAddCol(tc.blkIndex); tc.grid = tableRows(tc.blkIndex) } }
                                                }
                                            }
                                        }
                                    }

                                    // kanban board block
                                    Component {
                                        id: kanbanComp
                                        Flickable {
                                            id: kbFlick
                                            property int blkIndex: index
                                            property var board: kanbanData(index)
                                            // A Loader sizes its child to the child's IMPLICIT size, and
                                            // a Flickable has none on its own — so set it explicitly, or
                                            // the board collapses to 0px (invisible / un-clickable).
                                            implicitHeight: Math.max(120, kbRow.height)
                                            implicitWidth: kbRow.width
                                            contentWidth: kbRow.width
                                            contentHeight: kbRow.height
                                            clip: true
                                            flickableDirection: Flickable.HorizontalFlick
                                            // floating ghost shown while dragging a card
                                            Rectangle {
                                                id: kbDragProxy
                                                property string label: ""
                                                visible: false
                                                z: 9999
                                                width: 200; height: 34
                                                radius: Theme.spacing.radiusSmall
                                                color: Theme.palette.backgroundSecondary
                                                border.color: Theme.palette.primary; border.width: 1
                                                opacity: 0.92
                                                Drag.keys: ["kb-card"]
                                                Drag.hotSpot.x: 0; Drag.hotSpot.y: 0
                                                LogosText {
                                                    anchors.fill: parent; anchors.leftMargin: 8
                                                    verticalAlignment: Text.AlignVCenter
                                                    elide: Text.ElideRight
                                                    text: kbDragProxy.label
                                                    font.pixelSize: Theme.typography.secondaryText
                                                    color: Theme.palette.text
                                                }
                                            }

                                            Row {
                                                id: kbRow
                                                spacing: 10
                                                Repeater {
                                                    model: kbFlick.board.length
                                                    delegate: Rectangle {
                                                        property int ci: index
                                                        width: 240
                                                        height: kbCol.implicitHeight + 20
                                                        radius: Theme.spacing.radiusLarge
                                                        color: colDrop.containsDrag ? Theme.palette.backgroundMuted : Theme.palette.backgroundTertiary
                                                        border.color: colDrop.containsDrag ? Theme.palette.primary : "transparent"
                                                        border.width: 1
                                                        Behavior on color { ColorAnimation { duration: 80 } }

                                                        // drop target for cards dragged from any column
                                                        DropArea {
                                                            id: colDrop
                                                            anchors.fill: parent
                                                            keys: ["kb-card"]
                                                            onDropped: function(drop) {
                                                                if (root.dragKbCol >= 0) {
                                                                    kanbanMoveCard(kbFlick.blkIndex, root.dragKbCol, root.dragKbIdx, ci)
                                                                    kbFlick.board = kanbanData(kbFlick.blkIndex)
                                                                }
                                                                root.dragKbCol = -1; root.dragKbIdx = -1
                                                            }
                                                        }

                                                        ColumnLayout {
                                                            id: kbCol
                                                            anchors.top: parent.top
                                                            anchors.left: parent.left
                                                            anchors.right: parent.right
                                                            anchors.margins: 10
                                                            spacing: 6

                                                            // Column header — title + count + delete
                                                            RowLayout {
                                                                Layout.fillWidth: true
                                                                spacing: 6
                                                                TextField {
                                                                    Layout.fillWidth: true
                                                                    color: Theme.palette.text
                                                                    font.weight: Theme.typography.weightBold
                                                                    font.pixelSize: Theme.typography.primaryText
                                                                    placeholderText: "Untitled"
                                                                    placeholderTextColor: Theme.palette.textTertiary
                                                                    background: null
                                                                    leftPadding: 0; rightPadding: 0
                                                                    Component.onCompleted: text = (kbFlick.board[ci] ? kbFlick.board[ci].t : "")
                                                                    onTextChanged: kanbanSetColTitle(kbFlick.blkIndex, ci, text)
                                                                }
                                                                LogosText {
                                                                    text: kbFlick.board[ci] ? kbFlick.board[ci].cards.length : 0
                                                                    color: Theme.palette.textTertiary
                                                                    font.pixelSize: Theme.typography.secondaryText
                                                                }
                                                                LogosText {
                                                                    text: "×"; font.pixelSize: 15; color: colDelHover.containsMouse ? Theme.palette.error : Theme.palette.textTertiary
                                                                    MouseArea { id: colDelHover; anchors.fill: parent; anchors.margins: -4; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                                                        onClicked: { kanbanDeleteColumn(kbFlick.blkIndex, ci); kbFlick.board = kanbanData(kbFlick.blkIndex) } }
                                                                }
                                                            }

                                                            // Cards — a label (quick text) or a page (own doc).
                                                            Repeater {
                                                                model: kbFlick.board[ci] ? kbFlick.board[ci].cards.length : 0
                                                                delegate: Rectangle {
                                                                    property int k: index
                                                                    property var card: (kbFlick.board[ci] && kbFlick.board[ci].cards[k]) ? kbFlick.board[ci].cards[k] : ({})
                                                                    property bool isPage: card.kind === "page"
                                                                    property int cardId: isPage ? card.id : -1
                                                                    Layout.fillWidth: true
                                                                    Layout.preferredHeight: Math.max(40, lblCardText.implicitHeight + 16)
                                                                    radius: Theme.spacing.radiusSmall
                                                                    color: Theme.palette.backgroundSecondary
                                                                    border.color: cardHover.hovered ? Theme.palette.borderTertiary : Theme.palette.borderSubtle
                                                                    border.width: 1
                                                                    HoverHandler { id: cardHover }
                                                                    RowLayout {
                                                                        anchors.fill: parent; anchors.margins: 8; spacing: 4
                                                                        // drag handle → move card between/within columns
                                                                        LogosText {
                                                                            text: "⠿"; font.pixelSize: 12
                                                                            Layout.alignment: Qt.AlignTop
                                                                            opacity: cardHover.hovered ? 1 : 0
                                                                            color: cardGrip.pressed ? Theme.palette.text : Theme.palette.textTertiary
                                                                            MouseArea {
                                                                                id: cardGrip
                                                                                anchors.fill: parent; anchors.margins: -3
                                                                                hoverEnabled: true; preventStealing: true
                                                                                cursorShape: pressed ? Qt.ClosedHandCursor : Qt.OpenHandCursor
                                                                                property bool dragging: false
                                                                                onPressed: function(mouse) {
                                                                                    root.dragKbCol = ci; root.dragKbIdx = k
                                                                                    var pt = mapToItem(kbRow.parent, mouse.x, mouse.y)
                                                                                    kbDragProxy.x = pt.x + 6; kbDragProxy.y = pt.y + 6
                                                                                    kbDragProxy.label = (isPage ? docRawTitleById(cardId) : (card.text || "")) || "Card"
                                                                                    kbDragProxy.visible = true
                                                                                    kbDragProxy.Drag.start()
                                                                                    dragging = true
                                                                                }
                                                                                onPositionChanged: function(mouse) {
                                                                                    if (!dragging) return
                                                                                    var pt = mapToItem(kbRow.parent, mouse.x, mouse.y)
                                                                                    kbDragProxy.x = pt.x + 6; kbDragProxy.y = pt.y + 6
                                                                                }
                                                                                onReleased: {
                                                                                    if (dragging) { kbDragProxy.Drag.drop(); kbDragProxy.visible = false; dragging = false }
                                                                                }
                                                                            }
                                                                        }
                                                                        LogosText { visible: isPage; text: "📄"; font.pixelSize: 12; Layout.alignment: Qt.AlignTop }
                                                                        // page card → title (rename); label card → free text
                                                                        TextArea {
                                                                            id: lblCardText
                                                                            Layout.fillWidth: true
                                                                            wrapMode: Text.WordWrap; selectByMouse: true
                                                                            color: Theme.palette.text
                                                                            font.pixelSize: Theme.typography.secondaryText
                                                                            placeholderText: isPage ? "Untitled" : "Card…"
                                                                            placeholderTextColor: Theme.palette.textTertiary
                                                                            background: null; leftPadding: 0; rightPadding: 0; topPadding: 0; bottomPadding: 0
                                                                            Component.onCompleted: text = isPage ? docRawTitleById(cardId) : (card.text || "")
                                                                            onTextChanged: {
                                                                                if (isPage) { if (cardId >= 0) callModAsync("lotion", "renameDocument", [String(cardId), text], function(){}) }
                                                                                else kanbanSetCardText(kbFlick.blkIndex, ci, k, text)
                                                                            }
                                                                        }
                                                                        // label → promote to a page
                                                                        LogosText {
                                                                            visible: cardHover.hovered && !isPage
                                                                            text: "⤢"; font.pixelSize: 13
                                                                            color: promoteHover.containsMouse ? Theme.palette.primary : Theme.palette.textTertiary
                                                                            Layout.alignment: Qt.AlignTop
                                                                            ToolTip.visible: promoteHover.containsMouse; ToolTip.text: "Turn into a page"; ToolTip.delay: 350
                                                                            MouseArea { id: promoteHover; anchors.fill: parent; anchors.margins: -4; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                                                                onClicked: {
                                                                                    var bi = kbFlick.blkIndex, c = ci, kk = k, t = lblCardText.text
                                                                                    callModAsync("lotion", "createChildDocument", [String(currentId)], function(raw) {
                                                                                        var id = unwrapInt(raw, -1); if (id < 0) return
                                                                                        if (t.length) callModAsync("lotion", "renameDocument", [String(id), t], function(){})
                                                                                        kanbanPromoteToPage(bi, c, kk, id)
                                                                                        refreshDocuments()
                                                                                        kbFlick.board = kanbanData(bi)
                                                                                        openDoc(id)
                                                                                    })
                                                                                } }
                                                                        }
                                                                        // page → open
                                                                        LogosText {
                                                                            visible: cardHover.hovered && isPage
                                                                            text: "⤢"; font.pixelSize: 13
                                                                            color: openCardHover.containsMouse ? Theme.palette.primary : Theme.palette.textTertiary
                                                                            Layout.alignment: Qt.AlignTop
                                                                            ToolTip.visible: openCardHover.containsMouse; ToolTip.text: "Open page"; ToolTip.delay: 350
                                                                            MouseArea { id: openCardHover; anchors.fill: parent; anchors.margins: -4; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                                                                onClicked: if (cardId >= 0) openDoc(cardId) }
                                                                        }
                                                                        // delete card (+ its page if any)
                                                                        LogosText {
                                                                            visible: cardHover.hovered
                                                                            text: "×"; font.pixelSize: 13; color: cardDelHover.containsMouse ? Theme.palette.error : Theme.palette.textTertiary
                                                                            Layout.alignment: Qt.AlignTop
                                                                            MouseArea { id: cardDelHover; anchors.fill: parent; anchors.margins: -4; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                                                                onClicked: {
                                                                                    var bi = kbFlick.blkIndex, c = ci, kk = k, pg = isPage, cid = cardId
                                                                                    kanbanRemoveCardAt(bi, c, kk)
                                                                                    kbFlick.board = kanbanData(bi)
                                                                                    if (pg && cid >= 0) callModAsync("lotion", "deleteDocument", [String(cid)], function(){ refreshDocuments() })
                                                                                } }
                                                                        }
                                                                    }
                                                                }
                                                            }

                                                            // Add card — quick label, or a full page
                                                            RowLayout {
                                                                Layout.fillWidth: true
                                                                Layout.topMargin: 2
                                                                spacing: 4
                                                                Rectangle {
                                                                    Layout.fillWidth: true
                                                                    Layout.preferredHeight: 30
                                                                    radius: Theme.spacing.radiusSmall
                                                                    color: addLabelHover.containsMouse ? Theme.palette.backgroundMuted : "transparent"
                                                                    RowLayout {
                                                                        anchors.fill: parent; anchors.leftMargin: 6; spacing: 6
                                                                        LogosText { text: "+"; font.pixelSize: 15; color: Theme.palette.textSecondary }
                                                                        LogosText { Layout.fillWidth: true; text: "New"; font.pixelSize: Theme.typography.secondaryText; color: Theme.palette.textSecondary }
                                                                    }
                                                                    MouseArea { id: addLabelHover; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                                                        onClicked: { kanbanAddLabel(kbFlick.blkIndex, ci); kbFlick.board = kanbanData(kbFlick.blkIndex) } }
                                                                }
                                                                Rectangle {
                                                                    Layout.preferredWidth: 34; Layout.preferredHeight: 30
                                                                    radius: Theme.spacing.radiusSmall
                                                                    color: addPageHover.containsMouse ? Theme.palette.backgroundMuted : "transparent"
                                                                    LogosText { anchors.centerIn: parent; text: "📄"; font.pixelSize: 13 }
                                                                    ToolTip.visible: addPageHover.containsMouse; ToolTip.text: "New page card"; ToolTip.delay: 350
                                                                    MouseArea { id: addPageHover; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                                                        onClicked: {
                                                                            var bi = kbFlick.blkIndex, c = ci
                                                                            callModAsync("lotion", "createChildDocument", [String(currentId)], function(raw) {
                                                                                var id = unwrapInt(raw, -1); if (id < 0) return
                                                                                kanbanPushPageCard(bi, c, id)
                                                                                refreshDocuments()
                                                                                kbFlick.board = kanbanData(bi)
                                                                            })
                                                                        } }
                                                                }
                                                            }
                                                        }
                                                    }
                                                }

                                                // + Add a column
                                                Rectangle {
                                                    width: 160; height: 44
                                                    radius: Theme.spacing.radiusLarge
                                                    color: addColHover.containsMouse ? Theme.palette.backgroundTertiary : "transparent"
                                                    border.color: Theme.palette.borderSubtle; border.width: 1
                                                    LogosText { anchors.centerIn: parent; text: "+ Add a column"; font.pixelSize: Theme.typography.secondaryText; color: Theme.palette.textSecondary }
                                                    MouseArea { id: addColHover; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                                        onClicked: { kanbanAddColumn(kbFlick.blkIndex); kbFlick.board = kanbanData(kbFlick.blkIndex) } }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                // Page menu (⋯) popover
                MouseArea { anchors.fill: parent; visible: pageMenuOpen; onClicked: pageMenuOpen = false }
                Rectangle {
                    visible: pageMenuOpen
                    anchors.top: editorBar.bottom
                    anchors.right: parent.right
                    anchors.topMargin: Theme.spacing.small
                    anchors.rightMargin: Theme.spacing.xlarge + 140
                    width: 200
                    height: pmCol.implicitHeight + 12
                    radius: Theme.spacing.radiusLarge
                    color: Theme.palette.backgroundSecondary
                    border.color: Theme.palette.borderSubtle; border.width: 1
                    z: 50
                    ColumnLayout {
                        id: pmCol
                        anchors.fill: parent; anchors.margins: 6; spacing: 1
                        Repeater {
                            model: [
                                { lbl: "Duplicate",        act: "dup" },
                                { lbl: "Copy as Markdown", act: "copy" }
                            ]
                            delegate: Rectangle {
                                Layout.fillWidth: true; Layout.preferredHeight: 32
                                radius: Theme.spacing.radiusSmall
                                color: pmHover.containsMouse ? Theme.palette.backgroundMuted : "transparent"
                                LogosText { anchors.verticalCenter: parent.verticalCenter; anchors.left: parent.left; anchors.leftMargin: 10; text: modelData.lbl; color: Theme.palette.text; font.pixelSize: Theme.typography.secondaryText }
                                MouseArea { id: pmHover; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                    onClicked: { if (modelData.act === "dup") duplicateCurrent(); else copyCurrentMarkdown() } }
                            }
                        }
                    }
                }

                // Icon picker popover
                MouseArea { anchors.fill: parent; visible: iconPickerOpen; onClicked: iconPickerOpen = false }
                Rectangle {
                    visible: iconPickerOpen
                    anchors.top: editorBar.bottom
                    anchors.horizontalCenter: parent.horizontalCenter
                    anchors.topMargin: Theme.spacing.xlarge
                    width: 280
                    height: ipCol.implicitHeight + 20
                    radius: Theme.spacing.radiusLarge
                    color: Theme.palette.backgroundSecondary
                    border.color: Theme.palette.borderSubtle; border.width: 1
                    z: 50
                    ColumnLayout {
                        id: ipCol
                        anchors.fill: parent; anchors.margins: 10; spacing: 8
                        RowLayout {
                            Layout.fillWidth: true
                            LogosText { Layout.fillWidth: true; text: "Pick an icon"; color: Theme.palette.textTertiary; font.pixelSize: 11; font.weight: Theme.typography.weightMedium }
                            LogosText { visible: editorIcon.length > 0; text: "Remove"; color: Theme.palette.primary; font.pixelSize: Theme.typography.secondaryText
                                MouseArea { anchors.fill: parent; anchors.margins: -4; cursorShape: Qt.PointingHandCursor; onClicked: setPageIcon("") } }
                        }
                        GridLayout {
                            Layout.fillWidth: true
                            columns: 8; columnSpacing: 4; rowSpacing: 4
                            Repeater {
                                model: iconChoices
                                delegate: Rectangle {
                                    Layout.preferredWidth: 30; Layout.preferredHeight: 30
                                    radius: Theme.spacing.radiusSmall
                                    color: emojiHover.containsMouse ? Theme.palette.backgroundTertiary : "transparent"
                                    LogosText { anchors.centerIn: parent; text: modelData; font.pixelSize: 18 }
                                    MouseArea { id: emojiHover; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: setPageIcon(modelData) }
                                }
                            }
                        }
                    }
                }

                // Publish popover + scrim
                MouseArea {
                    anchors.fill: parent
                    visible: publishPanelOpen
                    onClicked: publishPanelOpen = false
                }
                Rectangle {
                    visible: publishPanelOpen
                    anchors.top: editorBar.bottom
                    anchors.right: parent.right
                    anchors.topMargin: Theme.spacing.small
                    anchors.rightMargin: Theme.spacing.xlarge
                    width: 320
                    height: pubCol.implicitHeight + Theme.spacing.large * 2
                    radius: Theme.spacing.radiusLarge
                    color: Theme.palette.backgroundSecondary
                    border.color: Theme.palette.borderSubtle
                    border.width: 1

                    ColumnLayout {
                        id: pubCol
                        anchors.fill: parent
                        anchors.margins: Theme.spacing.large
                        spacing: Theme.spacing.medium

                        LogosText {
                            text: "Publish to storage"
                            font.pixelSize: Theme.typography.primaryText
                            font.weight: Theme.typography.weightBold
                            color: Theme.palette.text
                        }
                        LogosText {
                            Layout.fillWidth: true
                            text: "Uploads this page to logos-storage and gives you a CID anyone can read."
                            font.pixelSize: Theme.typography.secondaryText
                            color: Theme.palette.textTertiary
                            wrapMode: Text.WordWrap
                        }

                        LogosCheckbox {
                            id: privateToggle
                            text: "Private (password-encrypted)"
                            checked: editorPrivate
                            onToggled: { editorPrivate = checked; scheduleSave() }
                        }
                        LogosTextField {
                            id: publishPassword
                            Layout.fillWidth: true
                            visible: editorPrivate
                            implicitHeight: 38
                            echoMode: TextInput.Password
                            placeholderText: "Password"
                        }

                        // Published result
                        Rectangle {
                            Layout.fillWidth: true
                            visible: publish.status === 2 && publish.cid.length
                            color: Theme.palette.backgroundSecondary
                            radius: Theme.spacing.radiusSmall
                            Layout.preferredHeight: cidRow.implicitHeight + Theme.spacing.medium * 2
                            RowLayout {
                                id: cidRow
                                anchors.fill: parent
                                anchors.margins: Theme.spacing.medium
                                spacing: Theme.spacing.small
                                LogosText {
                                    Layout.fillWidth: true
                                    text: shortCid(publish.cid)
                                    font.family: "monospace"
                                    font.pixelSize: Theme.typography.secondaryText
                                    color: Theme.palette.textSecondary
                                    elide: Text.ElideMiddle
                                }
                                LogosText {
                                    text: "⧉"
                                    font.pixelSize: 15
                                    color: copyPub.containsMouse ? Theme.palette.primary : Theme.palette.textSecondary
                                    ToolTip.visible: copyPub.containsMouse
                                    ToolTip.text: "Copy CID"
                                    MouseArea {
                                        id: copyPub
                                        anchors.fill: parent; anchors.margins: -4
                                        hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: { pubClip.text = publish.cid; pubClip.selectAll(); pubClip.copy() }
                                    }
                                }
                            }
                        }
                        TextEdit { id: pubClip; visible: false }

                        LogosText {
                            Layout.fillWidth: true
                            visible: publish.status === 3
                            text: publish.error
                            color: Theme.palette.error
                            font.pixelSize: Theme.typography.secondaryText
                            wrapMode: Text.WordWrap
                        }

                        LogosButton {
                            Layout.fillWidth: true
                            implicitHeight: 38
                            text: storageStatus !== 2 ? "Connecting to storage…"
                                : publish.status === 1 ? "Publishing…"
                                : publish.cid ? "Update published version"
                                : "Publish"
                            enabled: storageStatus === 2 && publish.status !== 1
                                     && titleField.text.trim().length > 0
                                     && blockModel.count > 0
                            onClicked: doPublish()
                        }
                    }
                }
            }

            // ─── READER ───
            Item {
                anchors.fill: parent
                visible: mode === "reader"

                // Reader top bar
                Rectangle {
                    id: readerBar
                    anchors.top: parent.top; anchors.left: parent.left; anchors.right: parent.right
                    height: 52
                    color: Theme.palette.background
                    Rectangle {
                        anchors.bottom: parent.bottom; anchors.left: parent.left; anchors.right: parent.right
                        height: 1; color: Theme.palette.borderSubtle
                    }
                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: Theme.spacing.xlarge
                        anchors.rightMargin: Theme.spacing.xlarge
                        spacing: Theme.spacing.medium
                        LogosText {
                            text: "← Workspace"
                            font.pixelSize: Theme.typography.secondaryText
                            color: Theme.palette.textSecondary
                            Layout.fillWidth: true
                            MouseArea {
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                onClicked: mode = (currentId >= 0 ? "editor" : "empty")
                            }
                        }
                        LogosButton {
                            visible: lastFetch.status === 2
                            text: "Duplicate to workspace"
                            implicitWidth: 200; implicitHeight: 36
                            onClicked: duplicateToWorkspace()
                        }
                    }
                }

                LogosScrollView {
                    id: readerScroll
                    anchors.top: readerBar.bottom; anchors.bottom: parent.bottom
                    anchors.left: parent.left; anchors.right: parent.right

                    Item {
                        width: readerScroll.width
                        implicitHeight: readerCol.implicitHeight + Theme.spacing.xxlarge * 2

                        ColumnLayout {
                            id: readerCol
                            anchors.horizontalCenter: parent.horizontalCenter
                            anchors.top: parent.top
                            anchors.topMargin: Theme.spacing.xlarge
                            width: Math.min(parent.width - Theme.spacing.xlarge * 2, 680)
                            spacing: Theme.spacing.large

                            // Password prompt
                            Rectangle {
                                Layout.fillWidth: true
                                visible: lastFetch.status === 4
                                color: Qt.rgba(Theme.palette.warning.r, Theme.palette.warning.g, Theme.palette.warning.b, 0.10)
                                border.color: Theme.palette.warning; border.width: 1
                                radius: Theme.spacing.radiusLarge
                                Layout.preferredHeight: pwCol.implicitHeight + Theme.spacing.large * 2
                                ColumnLayout {
                                    id: pwCol
                                    anchors.fill: parent
                                    anchors.margins: Theme.spacing.large
                                    spacing: Theme.spacing.medium
                                    LogosText {
                                        text: "🔒  This article is private"
                                        font.pixelSize: Theme.typography.subtitleText
                                        font.weight: Theme.typography.weightBold
                                        color: Theme.palette.text
                                    }
                                    LogosText {
                                        Layout.fillWidth: true
                                        text: lastFetch.error
                                        color: Theme.palette.textSecondary
                                        font.pixelSize: Theme.typography.secondaryText
                                        wrapMode: Text.WordWrap
                                    }
                                    RowLayout {
                                        Layout.fillWidth: true
                                        spacing: Theme.spacing.small
                                        LogosTextField {
                                            id: readerPassword
                                            Layout.fillWidth: true
                                            implicitHeight: 42
                                            echoMode: TextInput.Password
                                            placeholderText: "Password"
                                            Connections {
                                                target: readerPassword.textInput
                                                function onAccepted() { openByCid(lastFetch.cid) }
                                            }
                                        }
                                        LogosButton {
                                            text: "Unlock"
                                            implicitWidth: 100; implicitHeight: 42
                                            enabled: readerPassword.text.length > 0
                                            onClicked: openByCid(lastFetch.cid)
                                        }
                                    }
                                }
                            }

                            // Loading
                            RowLayout {
                                Layout.fillWidth: true
                                visible: lastFetch.status === 1 || lastFetch.status === 5
                                spacing: Theme.spacing.medium
                                LogosSpinner { implicitWidth: 20; implicitHeight: 20; thickness: 2; dotSize: 4; ringColor: Theme.palette.primary }
                                LogosText {
                                    text: lastFetch.status === 5 ? "Decrypting…" : "Fetching from logos-storage…"
                                    color: Theme.palette.textSecondary
                                    font.pixelSize: Theme.typography.subtitleText
                                }
                            }

                            // Error
                            Rectangle {
                                Layout.fillWidth: true
                                visible: lastFetch.status === 3
                                color: Qt.rgba(Theme.palette.error.r, Theme.palette.error.g, Theme.palette.error.b, 0.10)
                                border.color: Theme.palette.error; border.width: 1
                                radius: Theme.spacing.radiusLarge
                                Layout.preferredHeight: rerr.implicitHeight + Theme.spacing.large * 2
                                LogosText {
                                    id: rerr
                                    anchors.fill: parent; anchors.margins: Theme.spacing.large
                                    text: "Couldn't load this article: " + lastFetch.error
                                    color: Theme.palette.error
                                    font.pixelSize: Theme.typography.secondaryText
                                    wrapMode: Text.WordWrap
                                }
                            }

                            // Article
                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: Theme.spacing.large
                                visible: lastFetch.status === 2

                                // Cover — gradient, or the downloaded image
                                // once its bytes arrive from storage.
                                Rectangle {
                                    Layout.fillWidth: true
                                    Layout.preferredHeight: 220
                                    radius: Theme.spacing.radiusLarge
                                    clip: true
                                    gradient: Gradient {
                                        GradientStop { position: 0.0; color: gradientColors(coverGradient(lastFetch.cover))[0] }
                                        GradientStop { position: 1.0; color: gradientColors(coverGradient(lastFetch.cover))[1] }
                                    }
                                    Image {
                                        id: readerCoverImg
                                        anchors.fill: parent
                                        visible: coverIsImage(lastFetch.cover) && coverImagePath !== ""
                                        source: coverImagePath !== "" ? normaliseUrl(coverImagePath) : ""
                                        fillMode: Image.Stretch
                                        // Honour the author's saved crop focus.
                                        sourceClipRect: coverClip(readerCoverImg,
                                                                  coverFocusX(lastFetch.cover),
                                                                  coverFocusY(lastFetch.cover))
                                    }
                                    // Subtle loading hint while the cover image downloads.
                                    LogosText {
                                        anchors.centerIn: parent
                                        visible: coverIsImage(lastFetch.cover) && coverImagePath === ""
                                        text: "loading cover…"
                                        color: "#ffffff"; opacity: 0.8
                                        font.pixelSize: Theme.typography.secondaryText
                                    }
                                }
                                RowLayout {
                                    Layout.fillWidth: true
                                    Layout.topMargin: Theme.spacing.medium
                                    visible: lastFetch.isPrivate
                                    LogosBadge { text: "PRIVATE"; color: Theme.palette.warning }
                                }
                                LogosText {
                                    Layout.fillWidth: true
                                    Layout.topMargin: lastFetch.isPrivate ? 0 : Theme.spacing.medium
                                    text: lastFetch.title || "(untitled)"
                                    font.pixelSize: Theme.typography.pageTitleText
                                    font.weight: Theme.typography.weightBold
                                    color: Theme.palette.text
                                    wrapMode: Text.WordWrap
                                    lineHeight: 1.15
                                }
                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: Theme.spacing.medium
                                    LogosText {
                                        text: lastFetch.publishedAt ? relativeTime(lastFetch.publishedAt) : "just now"
                                        font.pixelSize: Theme.typography.secondaryText
                                        color: Theme.palette.textTertiary
                                    }
                                    Rectangle { Layout.preferredWidth: 3; Layout.preferredHeight: 3; radius: 1.5; color: Theme.palette.textTertiary; Layout.alignment: Qt.AlignVCenter }
                                    LogosText { text: "by anonymous"; font.pixelSize: Theme.typography.secondaryText; color: Theme.palette.textTertiary }
                                    Rectangle { Layout.preferredWidth: 3; Layout.preferredHeight: 3; radius: 1.5; color: Theme.palette.textTertiary; Layout.alignment: Qt.AlignVCenter }
                                    LogosText { text: shortCid(lastFetch.cid); font.family: "monospace"; font.pixelSize: Theme.typography.secondaryText; color: Theme.palette.textTertiary }
                                    LogosText {
                                        text: "⧉"; font.pixelSize: 15
                                        color: copyReader.containsMouse ? Theme.palette.primary : Theme.palette.textSecondary
                                        ToolTip.visible: copyReader.containsMouse
                                        ToolTip.text: "Copy CID"
                                        MouseArea {
                                            id: copyReader
                                            anchors.fill: parent; anchors.margins: -4
                                            hoverEnabled: true
                                            cursorShape: Qt.PointingHandCursor
                                            onClicked: { readerClip.text = lastFetch.cid; readerClip.selectAll(); readerClip.copy() }
                                        }
                                    }
                                    Item { Layout.fillWidth: true }
                                }
                                TextEdit { id: readerClip; visible: false }

                                Rectangle {
                                    Layout.fillWidth: true; Layout.preferredHeight: 1
                                    Layout.topMargin: Theme.spacing.large; Layout.bottomMargin: Theme.spacing.large
                                    color: Theme.palette.borderSubtle
                                }
                                TextEdit {
                                    Layout.fillWidth: true
                                    readOnly: true
                                    selectByMouse: true
                                    wrapMode: Text.WordWrap
                                    textFormat: TextEdit.RichText
                                    text: mdToHtml(lastFetch.body)
                                    font.family: Theme.typography.publicSans
                                    font.pixelSize: 17
                                    color: Theme.palette.text
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // ── Slash command popup (overlays everything; positioned at caret) ──
    MouseArea {
        anchors.fill: parent
        visible: slashOpen
        z: 999
        onClicked: closeSlash()
    }
    Rectangle {
        visible: slashOpen
        x: Math.max(8, Math.min(slashX, root.width - width - 8))
        y: Math.max(8, Math.min(slashY, root.height - height - 8))
        width: 300
        height: Math.min(slashCol.implicitHeight + 12, root.height - 24)
        color: Theme.palette.backgroundSecondary
        border.color: Theme.palette.borderSubtle
        border.width: 1
        radius: Theme.spacing.radiusLarge
        z: 1000
        clip: true
        ColumnLayout {
            id: slashCol
            anchors.fill: parent
            anchors.margins: 6
            spacing: 1

            // Section header
            LogosText {
                Layout.fillWidth: true
                Layout.leftMargin: 8
                Layout.topMargin: 4
                Layout.bottomMargin: 2
                text: "Basic blocks"
                color: Theme.palette.textTertiary
                font.pixelSize: 11
                font.weight: Theme.typography.weightMedium
            }

            Repeater {
                model: slashFiltered()
                delegate: Rectangle {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 38
                    radius: Theme.spacing.radiusSmall
                    color: index === slashSel ? Theme.palette.backgroundTertiary
                          : (smh.containsMouse ? Theme.palette.backgroundMuted : "transparent")
                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: 8
                        anchors.rightMargin: 12
                        spacing: 10
                        // Icon cell
                        Rectangle {
                            Layout.preferredWidth: 26; Layout.preferredHeight: 26
                            radius: Theme.spacing.radiusSmall
                            color: Theme.palette.backgroundTertiary
                            border.color: Theme.palette.borderSubtle; border.width: 1
                            LogosText {
                                anchors.centerIn: parent
                                text: modelData.glyph
                                color: Theme.palette.text
                                font.pixelSize: modelData.glyph.length > 2 ? 10 : 13
                                font.weight: Theme.typography.weightMedium
                            }
                        }
                        LogosText {
                            Layout.fillWidth: true
                            text: modelData.lbl
                            color: Theme.palette.text
                            font.pixelSize: Theme.typography.primaryText
                        }
                        // markdown shortcut hint
                        LogosText {
                            visible: modelData.hint.length > 0
                            text: modelData.hint
                            color: Theme.palette.textTertiary
                            font.family: "monospace"
                            font.pixelSize: Theme.typography.secondaryText
                        }
                    }
                    MouseArea {
                        id: smh
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onPositionChanged: slashSel = index
                        onClicked: { slashSel = index; acceptSlash() }
                    }
                }
            }
            LogosText {
                visible: slashFiltered().length === 0
                Layout.fillWidth: true
                Layout.preferredHeight: 38
                leftPadding: 10
                verticalAlignment: Text.AlignVCenter
                text: "No matches"
                color: Theme.palette.textTertiary
                font.pixelSize: Theme.typography.primaryText
            }

            // Footer: Close menu · esc
            Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; Layout.topMargin: 2; color: Theme.palette.borderSubtle }
            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: 32
                radius: Theme.spacing.radiusSmall
                color: closeMh.containsMouse ? Theme.palette.backgroundMuted : "transparent"
                RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: 8
                    anchors.rightMargin: 12
                    LogosText { Layout.fillWidth: true; text: "Close menu"; color: Theme.palette.text; font.pixelSize: Theme.typography.secondaryText }
                    LogosText { text: "esc"; color: Theme.palette.textTertiary; font.pixelSize: Theme.typography.secondaryText }
                }
                MouseArea { id: closeMh; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: closeSlash() }
            }
        }
    }

    // Floating ghost while dragging a sidebar page (re-parent)
    Rectangle {
        id: pageDragProxy
        property string label: ""
        visible: false
        z: 99999
        width: 190; height: 28
        radius: Theme.spacing.radiusSmall
        color: Theme.palette.backgroundSecondary
        border.color: Theme.palette.primary; border.width: 1
        opacity: 0.92
        Drag.keys: ["page-row"]
        Drag.hotSpot.x: 0; Drag.hotSpot.y: 0
        LogosText {
            anchors.fill: parent; anchors.leftMargin: 8
            verticalAlignment: Text.AlignVCenter
            elide: Text.ElideRight
            text: pageDragProxy.label
            font.pixelSize: Theme.typography.secondaryText
            color: Theme.palette.text
        }
    }
}
