import XCTest
import Combine
@testable import AsyncFlatMap

final class Publisher_Async_BindTests: XCTestCase {
    
    private var cancellables: Set<AnyCancellable>!
    private var subject: PassthroughSubject<Int, Error>!

    private var didCacncelled: (() -> Void)?
    
    override func setUpWithError() throws {
        self.cancellables = .init()
        self.subject = .init()
    }
    
    override func tearDownWithError() throws {
        self.cancellables.forEach { $0.cancel() }
        self.cancellables = nil
        self.subject = nil
        self.didCacncelled = nil
    }
    
    func increase(
        _ int: Int,
        shouldFail: Bool = false,
        sleep nanoseconds: UInt64 = 100
    ) async throws -> Int {
        let cancelled: @Sendable () -> Void = {
            self.didCacncelled?()
        }
        
        let increaseAction: () async throws -> Int = {
            try await Task.sleep(nanoseconds: nanoseconds)
            guard shouldFail == false
            else {
                throw RuntimeError()
            }
            return int + 1
        }
        return try await withTaskCancellationHandler(operation: increaseAction, onCancel: cancelled)
    }
    
    private func waitShortly(_ interval: TimeInterval = 0.05) {
        let expect = expectation(description: "wait \(interval)")
        DispatchQueue.main.asyncAfter(deadline: .now() + interval) {
            expect.fulfill()
        }
        self.wait(for: [expect], timeout: interval + 1.0)
    }
}

extension Publisher_Async_BindTests {
    
    func test_runAsyncExpression() {
        // given
        let expect = expectation(description: "wait result")
        var result: Int?
        
        // when
        self.subject
            .flatMap { int async throws -> Int? in
                let two = try await self.increase(int)
                let three = try await self.increase(two)
                return three
            }
            .sink(receiveCompletion: { _ in }, receiveValue: {
                result = $0
                expect.fulfill()
            })
            .store(in: &self.cancellables)
        self.subject.send(1)
        self.wait(for: [expect], timeout: 0.1)
            
        // then
        XCTAssertEqual(result, 3)
    }
    
    func test_runAsyncExpressionFail() {
        // given
        let expect = expectation(description: "run expression failed")
        var failure: Error?
        
        // when
        self.subject
            .flatMap { int async throws -> Int? in
                let two = try await self.increase(int)
                let three = try await self.increase(two, shouldFail: true)
                return three
            }
            .sink(receiveCompletion: { completion in
                guard case let .failure(error) = completion else { return }
                failure = error
                expect.fulfill()
            }, receiveValue: { _ in })
            .store(in: &self.cancellables)
        
        self.subject.send(1)
        self.wait(for: [expect], timeout: 0.1)
        
        // then
        XCTAssertNotNil(failure)
    }
    
    func test_runExpression_cancelled() {
        // given
        let expect = expectation(description: "run expression will cancel")
        expect.assertForOverFulfill = false

        self.didCacncelled = {
            expect.fulfill()
        }

        // when
        let cancellable = self.subject
            .flatMap { int async throws -> Int? in
                var result: Int = int
                for _ in 0..<100 {
                    result = try await self.increase(result, sleep: 10_000_000)
                }
                return result
            }
            .sink(receiveCompletion: { _ in }, receiveValue: { _ in })
        self.subject.send(1)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            cancellable.cancel()
        }

        // then
        self.wait(for: [expect], timeout: 1.0)
    }
}


private struct NotAFailureTypeError: Error { }


// MARK: - expression result

extension Publisher_Async_BindTests {
    
    func test_whenExpressionReturnsNil_finishWithoutValue() {
        // given
        let expect = expectation(description: "finish without value when expression returns nil")
        var values: [Int] = []
        
        // when
        let publisher: some Publisher<Int, any Error> = Publishers.create {
            return nil
        }
        publisher
            .sink(receiveCompletion: { completion in
                guard case .finished = completion else { return }
                expect.fulfill()
            }, receiveValue: { values.append($0) })
            .store(in: &self.cancellables)
        self.wait(for: [expect], timeout: 0.5)
        
        // then
        XCTAssertEqual(values, [])
    }
    
    func test_whenExpressionReturnsNilForOptionalType_finishWithNilValue() {
        // given
        let expect = expectation(description: "emit nil as a value when output type is optional")
        var values: [Int?] = []
        
        // when
        let publisher: some Publisher<Int?, any Error> = Publishers.create {
            return Optional<Int>.none
        }
        
        publisher
            .sink(receiveCompletion: { completion in
                guard case .finished = completion else { return }
                expect.fulfill()
            }, receiveValue: { values.append($0) })
            .store(in: &self.cancellables)
        self.wait(for: [expect], timeout: 0.5)
        
        // then
        XCTAssertEqual(values, [nil])
    }
    
    func test_whenErrorIsNotCastableToFailureType_finishWithoutFailure() {
        // given
        let expect = expectation(description: "finish when error is not castable to failure type")
        var completion: Subscribers.Completion<RuntimeError>?
        
        // when
        let publisher: some Publisher<Int, RuntimeError> = Publishers.create {
            throw NotAFailureTypeError()
        }
        publisher
            .sink(receiveCompletion: {
                completion = $0
                expect.fulfill()
            }, receiveValue: { _ in })
            .store(in: &self.cancellables)
        self.wait(for: [expect], timeout: 0.5)
        
        // then
        guard case .finished = completion
        else {
            XCTFail("should finish, but: \(String(describing: completion))")
            return
        }
    }
}


// MARK: - Publishers.create

extension Publisher_Async_BindTests {
    
    func test_createPublisher_emitValueAndFinish() {
        // given
        let expect = expectation(description: "emit value and finish")
        expect.expectedFulfillmentCount = 2
        var value: Int?
        var isFinished = false
        
        // when
        let publisher: some Publisher<Int?, any Error> = Publishers.create {
            try await Task.sleep(nanoseconds: 1_000_000)
            return 100
        }
        publisher
            .sink(receiveCompletion: { completion in
                guard case .finished = completion else { return }
                isFinished = true
                expect.fulfill()
            }, receiveValue: {
                value = $0
                expect.fulfill()
            })
            .store(in: &self.cancellables)
        self.wait(for: [expect], timeout: 0.5)
        
        // then
        XCTAssertEqual(value, 100)
        XCTAssertTrue(isFinished)
    }
    
    func test_createPublisher_whenExpressionThrows_emitFailure() {
        // given
        let expect = expectation(description: "emit failure")
        var failure: RuntimeError?
        
        // when
        let publisher: some Publisher<Int?, RuntimeError> = Publishers.create {
            throw RuntimeError("create failed")
        }
        publisher
            .sink(receiveCompletion: { completion in
                guard case let .failure(error) = completion else { return }
                failure = error
                expect.fulfill()
            }, receiveValue: { _ in })
            .store(in: &self.cancellables)
        self.wait(for: [expect], timeout: 0.5)
        
        // then
        XCTAssertEqual(failure?.message, "create failed")
    }
}


// MARK: - demand

extension Publisher_Async_BindTests {
    
    @available(iOS 15.0, macOS 12.0, tvOS 15.0, watchOS 8.0, *)
    func test_whenNotConsumed_notRunExpression() async throws {
        // given
        let didRun = Lock(false)
        let publisher: some Publisher<Int, any Error> = Publishers.create {
            didRun.set(true)
            return 1
        }
        
        // when: no demand is requested until the stream is iterated
        let values = publisher.values
        try await Task.sleep(nanoseconds: 50_000_000)
        
        // then
        XCTAssertEqual(didRun.value, false)
        
        // and when
        var received: [Int] = []
        for try await value in values {
            received.append(value)
        }
        
        // then
        XCTAssertEqual(didRun.value, true)
        XCTAssertEqual(received, [1])
    }
    
    @available(iOS 15.0, macOS 12.0, tvOS 15.0, watchOS 8.0, *)
    func test_whenSlowConsumerRequestsDemandIncrementally_runExpressionOncePerValue() async throws {
        // given
        let runCount = Lock(0)
        let values = self.subject
            .flatMap { int async throws -> Int? in
                runCount.set(runCount.value + 1)
                try await Task.sleep(nanoseconds: 5_000_000)
                return int * 10
            }
            .values
        
        // when: a for-await consumer requests max(1) demand again on each value it takes
        let sending = Task { [subject] in
            for int in 1...3 {
                subject?.send(int)
                try? await Task.sleep(nanoseconds: 2_000_000)
            }
        }
        var received: [Int] = []
        for try await value in values {
            received.append(value)
            try await Task.sleep(nanoseconds: 20_000_000)
            guard received.count < 3 else { break }
        }
        _ = await sending.result
        
        // then
        XCTAssertEqual(received.sorted(), [10, 20, 30])
        XCTAssertEqual(runCount.value, 3)
    }
}


// MARK: - termination while running

extension Publisher_Async_BindTests {
    
    func test_whenCancelledWhileRunning_deliverNothing() {
        // given
        let noValue = expectation(description: "no value should arrive after cancel")
        noValue.isInverted = true
        let noCompletion = expectation(description: "no completion should arrive after cancel")
        noCompletion.isInverted = true
        
        let publisher: some Publisher<Int, any Error> = Publishers.create {
            try await Task.sleep(nanoseconds: 200_000_000)
            return 1
        }
        let cancellable = publisher
            .sink(receiveCompletion: { _ in
                noCompletion.fulfill()
            }, receiveValue: { _ in
                noValue.fulfill()
            })
        
        // when
        self.waitShortly(0.02)
        cancellable.cancel()
        
        // then: nothing should arrive even after the expression would have finished (200ms)
        self.wait(for: [noValue, noCompletion], timeout: 0.3)
    }
    
    func test_whenUpstreamFailsWhileRunning_emitUpstreamFailure() {
        // given
        let failureExpect = expectation(description: "emit upstream failure")
        let noValue = expectation(description: "no value should arrive from the running expression")
        noValue.isInverted = true
        var failure: Error?
        
        // when
        self.subject
            .flatMap { int async throws -> Int? in
                try await Task.sleep(nanoseconds: 200_000_000)
                return int + 1
            }
            .sink(receiveCompletion: { completion in
                guard case let .failure(error) = completion else { return }
                failure = error
                failureExpect.fulfill()
            }, receiveValue: { _ in noValue.fulfill() })
            .store(in: &self.cancellables)
        
        self.subject.send(1)
        self.subject.send(completion: .failure(RuntimeError("upstream")))
        
        // then
        self.wait(for: [failureExpect, noValue], timeout: 0.3)
        XCTAssertEqual((failure as? RuntimeError)?.message, "upstream")
    }
}


// MARK: - multiple upstream values

extension Publisher_Async_BindTests {
    
    func test_whenUpstreamEmitsMultipleValues_emitResultForEachValue() {
        // given
        let expect = expectation(description: "emit result for each upstream value")
        expect.expectedFulfillmentCount = 3
        let values = Lock([Int]())
        
        // when
        self.subject
            .flatMap { int async throws -> Int? in
                try await Task.sleep(nanoseconds: 1_000_000)
                return int * 10
            }
            .sink(receiveCompletion: { _ in }, receiveValue: {
                values.set(values.value + [$0])
                expect.fulfill()
            })
            .store(in: &self.cancellables)
        
        self.subject.send(1)
        self.subject.send(2)
        self.subject.send(3)
        self.wait(for: [expect], timeout: 0.5)
        
        // then
        XCTAssertEqual(values.value.sorted(), [10, 20, 30])
    }
}


// MARK: - test doubles

private final class Lock<V>: @unchecked Sendable {
    
    private let lock = NSLock()
    private var _value: V
    
    init(_ value: V) {
        self._value = value
    }
    
    var value: V {
        self.lock.lock(); defer { self.lock.unlock() }
        return self._value
    }
    
    func set(_ newValue: V) {
        self.lock.lock(); defer { self.lock.unlock() }
        self._value = newValue
    }
}
