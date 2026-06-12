#ifndef LOTION_INTERFACE_H
#define LOTION_INTERFACE_H

#include <QObject>
#include <QString>
#include "interface.h"

// Part 7 — Publishing: a Notion-style local-first workspace on top of
// logos-storage.
//
// The plugin owns two responsibilities, both kept on the C++ side because
// neither touches storage_module IPC (which hangs when called from a C++
// plugin on macOS — the QML UI talks to storage_module directly):
//
//   1. Local workspace — a SQLite `documents` table. Pages are created,
//      edited, and autosaved entirely offline. Publishing is optional;
//      a page may live forever as a local draft.
//
//   2. Envelope crypto — when the user does publish, build/parse the
//      storage envelope (AES-256-GCM with a password-derived key for
//      private pages), via temp files the QML hands to storage_module.
//
// Basecamp's prerelease IPC marshals every QML Q_INVOKABLE arg as QString,
// so we keep signatures string-typed and parse inside (matches todo /
// filesharing).
class LotionInterface : public PluginInterface
{
public:
    virtual ~LotionInterface() = default;

    // ── Local workspace (SQLite) ─────────────────────────────────────

    // Create a fresh empty page. Returns its local id (or -1 on failure).
    Q_INVOKABLE virtual int     createDocument() = 0;

    // Create a page nested under `parentId` (Notion-style sub-page).
    Q_INVOKABLE virtual int     createChildDocument(const QString& parentId) = 0;

    // Update only a page's title (used to rename kanban card-pages in place).
    Q_INVOKABLE virtual bool    renameDocument(const QString& id,
                                               const QString& title) = 0;

    // Set a page's emoji icon ("" clears it).
    Q_INVOKABLE virtual bool    setIcon(const QString& id, const QString& icon) = 0;

    // Re-parent a page (drag-and-drop in the sidebar). `parentId` "" / "-1"
    // moves it to the top level. Rejects cycles (a page under its own subtree).
    Q_INVOKABLE virtual bool    setParent(const QString& id,
                                          const QString& parentId) = 0;

    // Duplicate a page (title gets " (copy)"). Returns the new id.
    Q_INVOKABLE virtual int     duplicateDocument(const QString& id) = 0;

    // Upsert a page's editable fields. `isPrivate` is "true"/"false".
    // Bumps updated_at. Does not touch cid / published_at.
    Q_INVOKABLE virtual bool    saveDocument(const QString& id,
                                             const QString& title,
                                             const QString& body,
                                             const QString& cover,
                                             const QString& isPrivate) = 0;

    // JSON array of all pages, newest-edited first. Each entry:
    //   { id, title, snippet, cover, isPrivate, cid, updatedAt, publishedAt }
    Q_INVOKABLE virtual QString listDocuments() = 0;

    // Full JSON of one page: adds `body` to the list-entry fields.
    // Returns "{}" if not found.
    Q_INVOKABLE virtual QString getDocument(const QString& id) = 0;

    Q_INVOKABLE virtual bool    deleteDocument(const QString& id) = 0;

    // Record that a page has been published to storage under `cid`.
    Q_INVOKABLE virtual bool    markPublished(const QString& id,
                                              const QString& cid) = 0;

    // Copy a user-picked image into `destDir` (the QML passes a folder
    // *inside the plugin's own directory* — the only place Basecamp's QML
    // sandbox will let an Image element load from). Returns the stable
    // local path (or "" on failure). The QML uploads this file to
    // logos-storage at publish time to get a portable image CID.
    Q_INVOKABLE virtual QString importCoverImage(const QString& srcUrl,
                                                 const QString& destDir) = 0;

    // Ensure `destDir` exists (mkpath) and return it. The reader uses this
    // to download a cover image into a sandbox-allowed folder before
    // pointing an Image at it.
    Q_INVOKABLE virtual QString ensureCoversDir(const QString& destDir) = 0;

    // ── Storage envelope helpers ─────────────────────────────────────

    // Build an envelope from a page and write it to a temp file; returns
    // the path for the QML to hand to storage_module.uploadUrl.
    // `password` empty = public; non-empty = AES-256-GCM encrypted.
    // `metaJson` is merged extra fields (publishedAt, cover, …).
    Q_INVOKABLE virtual QString prepareEnvelopeFile(const QString& title,
                                                    const QString& body,
                                                    const QString& password,
                                                    const QString& metaJson) = 0;

    // Read a downloaded envelope file, decrypt if private. Returns JSON:
    //   { ok:true, isPrivate, title, body, ...meta }
    //   { ok:false, needsPassword:true, error }
    //   { ok:false, error }
    Q_INVOKABLE virtual QString consumeEnvelopeFile(const QString& path,
                                                    const QString& password) = 0;
};

#define LotionInterface_iid "org.logos.LotionInterface"
Q_DECLARE_INTERFACE(LotionInterface, LotionInterface_iid)

#endif
