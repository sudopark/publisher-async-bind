# publisher-async-bind

🔥 A powerful tool for writing async/await statements within the Combine publisher event chain.

Combine's own operators are synchronous, so calling an `async` function from inside a chain normally means spawning a detached `Task` and bridging the result back through a subject by hand. `AsyncFlatMap` gives you an operator that takes the `async` expression directly and turns its result into a publisher event.

```swift
import Combine
import AsyncFlatMap

searchQuery
    .flatMap { query async throws -> [Article] in
        try await api.search(query)
    }
    .sink(receiveCompletion: { _ in }, receiveValue: { articles in
        render(articles)
    })
    .store(in: &cancellables)
```

## Installation

Add the package to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/sudopark/publisher-async-bind.git", from: "1.0.0")
]
```

then add `AsyncFlatMap` to your target:

```swift
.target(name: "MyApp", dependencies: [
    .product(name: "AsyncFlatMap", package: "publisher-async-bind")
])
```

## Usage

### Running an async expression per upstream value

`flatMap(do:)` runs the expression for each upstream value and emits its result. Each value gets its own task, so the expression may run concurrently for values that arrive while an earlier one is still in flight.

```swift
userIdSubject
    .flatMap { userId async throws -> Profile in
        try await repository.loadProfile(userId)
    }
    .sink(receiveCompletion: { _ in }, receiveValue: { profile in
        self.profile = profile
    })
    .store(in: &cancellables)
```

The expression's return type is declared as optional, but you are not required to write one. A non-optional return is promoted automatically, so all of these compile:

```swift
.flatMap { try await repository.loadProfile($0) }           // inferred
.flatMap { id async throws -> Profile in ... }              // non-optional
.flatMap { id async throws -> Profile? in ... }             // optional
```

### Skipping a value

Returning `nil` finishes that element without emitting anything. This is what the optional return is there for — it lets the weak-self guard end the element instead of forcing you to invent a value:

```swift
userIdSubject
    .flatMap { [weak self] userId async throws -> Profile? in
        guard let self else { return nil }
        return try await self.repository.loadProfile(userId)
    }
```

If the output type is itself optional, wrap one level deeper to emit `nil` as an actual value:

```swift
.flatMap { id async throws -> Profile?? in
    return Optional<Profile>.none        // emits nil as a value
}
```

### Starting a chain from a single async call

`Publishers.create(do:)` wraps one `async` call with no upstream. The failure type cannot be inferred from the closure, so annotate the result:

```swift
let profile: some Publisher<Profile, any Error> = Publishers.create {
    try await repository.loadProfile(currentUserId)
}

profile
    .receive(on: DispatchQueue.main)
    .sink(receiveCompletion: { _ in }, receiveValue: { render($0) })
    .store(in: &cancellables)
```

### Cancellation

Cancelling the subscription cancels the underlying `Task`, so `Task.checkCancellation()` and `withTaskCancellationHandler` inside the expression work as expected. No value or completion is delivered after cancellation.

```swift
let cancellable = publisher
    .flatMap { id async throws -> Profile in
        try await repository.loadProfile(id)     // cancelled with the subscription
    }
    .sink(receiveCompletion: { _ in }, receiveValue: { _ in })

cancellable.cancel()
```

## Behavior reference

| The expression | The stream |
| --- | --- |
| returns a value | emits it, then finishes |
| returns `nil` | finishes without emitting |
| throws an error matching the stream's `Failure` | fails with that error |
| throws an error that does not match `Failure` | finishes without failing |
| is cancelled | delivers nothing |

## Requirements

- Swift 5.7+
- iOS 13+ / macOS 10.15+ / tvOS 13+ / watchOS 6+

## Swift version support

The package ships two manifests and SwiftPM picks one for you, so nothing is required on your side:

| Your toolchain | Manifest resolved | The library is built in |
| --- | --- | --- |
| Swift 6.0+ | `Package.swift` (tools version 6.0) | the Swift 6 language mode |
| Swift 5.7 – 5.x | `Package@swift-5.swift` (tools version 5.7) | the Swift 5 language mode |

**Your module's language mode is independent of the library's.** A target in the Swift 5 language mode can depend on the library even though it was compiled in the Swift 6 language mode, and the other way round.

### Using it from the Swift 6 language mode

The expression is a `@Sendable` closure, so everything it captures must be `Sendable`:

```swift
final class ViewModel {                            // not Sendable
    func bind() {
        subject.flatMap { id async throws -> Profile in
            try await self.repository.load(id)     // ❌ capture of 'self' in a '@Sendable' closure
        }
    }
}
```

Capture only what the expression needs, and make that piece `Sendable`:

```swift
subject.flatMap { [repository] id async throws -> Profile in
    try await repository.load(id)                  // ✅ when repository is Sendable
}
```

## License

MIT. See [LICENSE](LICENSE).
