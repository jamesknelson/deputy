Global Buses
- API actions
- one for each resource type
- one for each index type

Resource events types
- fetch called
- operation called
- operation result
- data receiving (enables projection batching, so that multiple projection changes aren't emitted for one response)
- data received
- fetch result (has status, but no resource data, also ends batching)

Index event types
- fetch called
- fetch receiving (starts index batching, so all changes can be sent at once)
- fetch result (no index data, but used to update index status -> complete / error, and end batching)

---

The Model:
A list of all resource/index buses

Action store should:
- store all in-progress and failed-but-undismissed API operations (built from list of API events)
- emit the current list on subscription

Demultiplexers should:
- take a demux descriptor and model
- subscribe to a single type of API event
- emit master/opqueue/index events to the appropriate buses based on the stream of API events

Master stores should:
- take a function to make a fetch for a given set of ids
- emit a stream of updates to the resouce's state (as received from action bus)
- emit the current value on subscription
- request the current value be fetched if it isn't available on subscription

Opqueue stores should:
- emit a stream of changes to the currently queued operations (as received from action bus)
- emit the current operation queue on subscription
- remove successful operations as they complete
- remove redundant operations as the master store is updated

Projections should:
- emit a stream of changes to the currently active resource (opqueue projceted on master)
- emit the current value on subscription

Indexes should:
- take a function to make a fetch for a given key
- emit a stream of immutable-js sets with properties matching projected resources
- emit the current immutable-js set on subscription
- request the current set be fetched if it isn't complete on subscription

Multiplexers should:
- take a demux descriptor
- take a key for the root projection/index
- emit a stream of immutable-js values 
- emit the current immutable-js on subscription
- generally should be set up/cleaned up when routes change

---

Interface to components (and thus users):
- make API action
- subscribe to a multiplexer