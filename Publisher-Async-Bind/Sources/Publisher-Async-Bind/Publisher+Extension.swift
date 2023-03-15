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
    private var subscriber: S!
    private let expression: @Sendable (Input) async throws -> S.Input?
    
    private let lock = NSRecursiveLock()
    private var task: Task<Void, Never>?
    
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
        self.runExpression()
    }
    
    func cancel() {
        self.lock.lock(); defer { self.lock.unlock() }
        self.task?.cancel()
        self.subscriber = nil
    }
    
    private func runExpression() {
        
        let input = self.input
        self.task = Task { [weak self] in
            do {
                if let result = try await self?.expression(input) {
                    _ = self?.subscriber?.receive(result)
                }
                self?.subscriber?.receive(completion: .finished)
                
            } catch let error as S.Failure {
                self?.subscriber?.receive(completion: .failure(error))
            } catch {
                self?.subscriber?.receive(completion: .finished)
            }
        }
    }
}
