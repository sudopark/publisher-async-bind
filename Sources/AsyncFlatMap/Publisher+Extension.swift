//
//  File.swift
//  
//
//  Created by sudo.park on 2023/03/10.
//

import Foundation
import Combine


extension Publisher {
    
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
        guard task == nil, !isTerminated, demand > .none else { return }
        runExpression()
    }
    
    func cancel() {
        self.lock.lock()
        let task = self.task
        self.task = nil
        self.isTerminated = true
        self.lock.unlock()
        
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
        guard !isTerminated, !(error is CancellationError)
        else { self.lock.unlock(); return }
        self.lock.unlock()
        
        if let typedError = error as? S.Failure {
            subscriber.receive(completion: .failure(typedError))
        } else {
            subscriber.receive(completion: .finished)
        }
    }
}
