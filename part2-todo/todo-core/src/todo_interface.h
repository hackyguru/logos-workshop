#ifndef TODO_INTERFACE_H
#define TODO_INTERFACE_H

#include <QObject>
#include <QString>
#include "interface.h"

class TodoInterface : public PluginInterface
{
public:
    virtual ~TodoInterface() = default;

    Q_INVOKABLE virtual int     addTodo(const QString& title) = 0;
    Q_INVOKABLE virtual QString listTodos() = 0;
    // Basecamp prerelease (>= 0.1.2) marshals every QML Q_INVOKABLE arg as
    // QString, so methods called from `logos.callModule` must declare QString
    // params. We parse to int inside the implementation.
    Q_INVOKABLE virtual bool    completeTodo(const QString& id) = 0;
    Q_INVOKABLE virtual bool    removeTodo(const QString& id) = 0;
    Q_INVOKABLE virtual int     clearAll() = 0;
};

#define TodoInterface_iid "org.logos.TodoInterface"
Q_DECLARE_INTERFACE(TodoInterface, TodoInterface_iid)

#endif
