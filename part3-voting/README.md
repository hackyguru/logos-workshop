# Part 3: Voting App (stub)

Placeholder for the voting module.

Will be filled in once we wire up `logos-messaging`. Starts as a core module
with local-only `vote(option)` / `tally()` methods, then the messaging layer
turns it into a shared poll across multiple running instances.

Planned interface:

```cpp
Q_INVOKABLE virtual bool    vote(const QString& option) = 0;   // one of: watermelon, mango, apple, orange
Q_INVOKABLE virtual QString tally() = 0;                        // JSON: { "watermelon": 3, ... }
Q_INVOKABLE virtual QString myVote() = 0;                       // current vote from this instance
Q_INVOKABLE virtual int     resetPoll() = 0;
```
