#ifndef TODO_PLUGIN_H
#define TODO_PLUGIN_H

#include <QObject>
#include <QString>
#include "todo_interface.h"
#include "logos_api.h"
#include "logos_sdk.h"

class TodoPlugin : public QObject, public TodoInterface
{
    Q_OBJECT
    Q_PLUGIN_METADATA(IID TodoInterface_iid FILE "metadata.json")
    Q_INTERFACES(TodoInterface PluginInterface)

public:
    explicit TodoPlugin(QObject* parent = nullptr);
    ~TodoPlugin() override;

    QString name() const override { return "todo"; }
    QString version() const override { return "0.1.0"; }

    Q_INVOKABLE void initLogos(LogosAPI* api);

    Q_INVOKABLE int     addTodo(const QString& title) override;
    Q_INVOKABLE QString listTodos() override;
    Q_INVOKABLE bool    completeTodo(int id) override;
    Q_INVOKABLE bool    removeTodo(int id) override;
    Q_INVOKABLE int     clearAll() override;

signals:
    void eventResponse(const QString& eventName, const QVariantList& args);

private:
    bool openDatabase();
};

#endif
