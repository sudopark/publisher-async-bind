//
//  File.swift
//  
//
//  Created by sudo.park on 2023/03/10.
//

import Foundation
import Combine


extension Publisher {
    
    /// Runs an async expression for each upstream value and emits its result.
    ///
    /// Cancelling the subscription cancels the running task.
    ///
    /// - Parameters:
    ///   - maxPublishers: How many expressions may run at once. The default,
    ///     `.unlimited`, starts a value's expression even while earlier ones are still
    ///     running; `.max(1)` runs them one at a time.
    ///   - expression: The async work to run. Returning `nil` finishes that element
    ///     without emitting a value; a non-optional return is promoted, so the optional
    ///     is a permission rather than a requirement. An error is emitted as a failure
    ///     when it can be cast to the stream's `Failure`, and finishes the element
    ///     without failing when it cannot.
    public func flatMap<T>(
        maxPublishers: Subscribers.Demand = .unlimited,
        do expression: @Sendable @escaping (Output) async throws -> T?
    ) -> Publishers.FlatMap<AsyncFlatMapPublisher<Output, Self.Failure, T>, Self>
    {
        
        return self.flatMap(maxPublishers: maxPublishers) {
            return AsyncFlatMapPublisher($0, expression)
        }
    }
}

extension Publishers {
    
    /// Wraps a single async expression, with no upstream, into a publisher.
    ///
    /// The failure type cannot be inferred from the expression, so annotate the result
    /// (for example, `let p: some Publisher<Int, any Error> = Publishers.create { ... }`).
    public static func create<T, E: Error>(
        do expression: @Sendable @escaping () async throws -> T?
    ) -> AsyncFlatMapPublisher<Void, E, T> {
        return AsyncFlatMapPublisher((), expression)
    }
}


public struct AsyncFlatMapPublisher<Input, Failure: Error, Output>: Publisher {
    
    private let input: Input
    private let expression: @Sendable (Input) async throws -> Output?
    init(
        _ input: Input,
        _ expression: @Sendable @escaping (Input) async throws -> Output?
    ) {
        self.input = input
        self.expression = expression
    }
    
    public func receive<S>(subscriber: S) where S : Subscriber, Failure == S.Failure, Output == S.Input {
        let subscription = AsyncFlatMapSubscription(input: self.input, subscriber: subscriber, expression)
        subscriber.receive(subscription: subscription)
    }
    
    
}

// `@unchecked` because `Subscriber` is not Sendable: the lock covers the mutable
// state, and the subscriber is only ever touched from the single expression task.
private final class AsyncFlatMapSubscription<Input, S: Subscriber>: Subscription, @unchecked Sendable {
    
    private let input: Input
    private let subscriber: S
    private let expression: @Sendable (Input) async throws -> S.Input?
    
    private var task: Task<Void, Never>?
    private let lock = NSRecursiveLock()
    private var isTerminated = false
    
    init(
        input: Input,
        subscriber: S,
        _ expression: @Sendable @escaping (Input) async throws -> S.Input?
    ) {
        self.input = input
        self.subscriber = subscriber
        self.expression = expression
    }
    
    func request(_ demand: Subscribers.Demand) {
        self.lock.lock(); defer { self.lock.unlock() }
        // Demand is additive, so a subscriber may call this more than once. This
        // subscription is one-shot: an extra request must not start a second task.
        guard task == nil, !isTerminated, demand > .none else { return }
        runExpression()
    }
    
    func cancel() {
        self.lock.lock()
        let task = self.task
        self.task = nil
        self.isTerminated = true
        self.lock.unlock()
        
        // Outside the lock: cancellation handlers in the expression run synchronously
        // here and may re-enter this subscription.
        task?.cancel()
    }
    
    private func runExpression() {
        
        let input = self.input
        self.task = Task { [weak self] in
            do {
                let result = try await self?.expression(input)
                self?.deliver(result)
                
            } catch {
                self?.deliverError(error)
            }
        }
    }
    
    private func deliver(_ result: S.Input?) {
        self.lock.lock()
        guard !self.isTerminated
        else { self.lock.unlock(); return }
        self.lock.unlock()
        
        if let result {
            _ = subscriber.receive(result)
        }
        subscriber.receive(completion: .finished)
    }
    
    private func deliverError(_ error: any Error) {
        self.lock.lock()
        // A CancellationError means the subscription was torn down, not that the work
        // failed, so it is never surfaced downstream.
        guard !isTerminated, !(error is CancellationError)
        else { self.lock.unlock(); return }
        self.lock.unlock()
        
        if let typedError = error as? S.Failure {
            subscriber.receive(completion: .failure(typedError))
        } else {
            // The stream's Failure cannot represent this error, so finish instead.
            subscriber.receive(completion: .finished)
        }
    }
}
