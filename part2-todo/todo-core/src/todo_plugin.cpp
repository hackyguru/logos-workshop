#include "todo_plugin.h"
#include "logos_api.h"

#include <QDateTime>
#include <QDebug>
#include <QDir>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QSqlDatabase>
#include <QSqlError>
#include <QSqlQuery>
#include <QStandardPaths>
#include <QVariant>

// Named connection so our QSqlDatabase handle doesn't clash with anything else
// logos_host might open — standard Qt SQL multi-connection hygiene.
static constexpr char CONNECTION[] = "logos-workshop-todo";

TodoPlugin::TodoPlugin(QObject* parent)
    : QObject(parent)
{
    qDebug() << "TodoPlugin: ready";
}

TodoPlugin::~TodoPlugin()
{
    // Close + drop our named connection cleanly on unload.
    if (QSqlDatabase::contains(CONNECTION)) {
        {
            QSqlDatabase db = QSqlDatabase::database(CONNECTION);
            if (db.isOpen()) db.close();
        }
        QSqlDatabase::removeDatabase(CONNECTION);
    }
}

void TodoPlugin::initLogos(LogosAPI* api)
{
    logosAPI = api;
    if (!openDatabase()) {
        qWarning() << "TodoPlugin: database init failed — todos won't persist";
    }
}

bool TodoPlugin::openDatabase()
{
    // Writable per-app data directory. On macOS this is
    //   ~/Library/Application Support/<app>/todo.db
    // which persists across Basecamp restarts.
    const QString dataDir =
        QStandardPaths::writableLocation(QStandardPaths::AppDataLocation);
    QDir().mkpath(dataDir);
    const QString dbPath = dataDir + "/todo.db";

    QSqlDatabase db = QSqlDatabase::addDatabase("QSQLITE", CONNECTION);
    db.setDatabaseName(dbPath);
    if (!db.open()) {
        qWarning() << "TodoPlugin: cannot open" << dbPath << db.lastError();
        return false;
    }

    QSqlQuery q(db);
    if (!q.exec("CREATE TABLE IF NOT EXISTS todos ("
                "  id         INTEGER PRIMARY KEY AUTOINCREMENT,"
                "  title      TEXT    NOT NULL,"
                "  completed  INTEGER NOT NULL DEFAULT 0,"
                "  created_at INTEGER NOT NULL"
                ")")) {
        qWarning() << "TodoPlugin: create table failed:" << q.lastError();
        return false;
    }

    qDebug() << "TodoPlugin: database ready at" << dbPath;
    return true;
}

int TodoPlugin::addTodo(const QString& title)
{
    QSqlDatabase db = QSqlDatabase::database(CONNECTION);
    QSqlQuery q(db);
    q.prepare("INSERT INTO todos (title, completed, created_at) VALUES (?, 0, ?)");
    q.addBindValue(title);
    q.addBindValue(QDateTime::currentSecsSinceEpoch());
    if (!q.exec()) {
        qWarning() << "TodoPlugin::addTodo failed:" << q.lastError();
        return -1;
    }
    const int id = q.lastInsertId().toInt();
    qDebug() << "TodoPlugin::addTodo" << id << title;
    emit eventResponse("todoAdded", QVariantList{ id, title });
    return id;
}

QString TodoPlugin::listTodos()
{
    QJsonArray arr;
    QSqlDatabase db = QSqlDatabase::database(CONNECTION);
    QSqlQuery q(db);
    if (q.exec("SELECT id, title, completed FROM todos ORDER BY created_at DESC")) {
        while (q.next()) {
            QJsonObject obj;
            obj["id"]        = q.value(0).toInt();
            obj["title"]     = q.value(1).toString();
            obj["completed"] = q.value(2).toBool();
            arr.append(obj);
        }
    } else {
        qWarning() << "TodoPlugin::listTodos failed:" << q.lastError();
    }
    return QString::fromUtf8(QJsonDocument(arr).toJson(QJsonDocument::Compact));
}

bool TodoPlugin::completeTodo(int id)
{
    QSqlDatabase db = QSqlDatabase::database(CONNECTION);
    QSqlQuery q(db);
    q.prepare("UPDATE todos SET completed = 1 WHERE id = ?");
    q.addBindValue(id);
    if (!q.exec() || q.numRowsAffected() == 0) return false;
    qDebug() << "TodoPlugin::completeTodo" << id;
    emit eventResponse("todoCompleted", QVariantList{ id });
    return true;
}

bool TodoPlugin::removeTodo(int id)
{
    QSqlDatabase db = QSqlDatabase::database(CONNECTION);
    QSqlQuery q(db);
    q.prepare("DELETE FROM todos WHERE id = ?");
    q.addBindValue(id);
    if (!q.exec() || q.numRowsAffected() == 0) return false;
    qDebug() << "TodoPlugin::removeTodo" << id;
    emit eventResponse("todoRemoved", QVariantList{ id });
    return true;
}

int TodoPlugin::clearAll()
{
    QSqlDatabase db = QSqlDatabase::database(CONNECTION);
    QSqlQuery q(db);
    if (!q.exec("DELETE FROM todos")) {
        qWarning() << "TodoPlugin::clearAll failed:" << q.lastError();
        return 0;
    }
    const int n = q.numRowsAffected();
    qDebug() << "TodoPlugin::clearAll removed" << n;
    emit eventResponse("todosCleared", QVariantList{ n });
    return n;
}
