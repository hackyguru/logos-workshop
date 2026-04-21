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
    Q_INVOKABLE virtual bool    completeTodo(int id) = 0;
    Q_INVOKABLE virtual bool    removeTodo(int id) = 0;
    Q_INVOKABLE virtual int     clearAll() = 0;
};

#define TodoInterface_iid "org.logos.TodoInterface"
Q_DECLARE_INTERFACE(TodoInterface, TodoInterface_iid)

#endif
