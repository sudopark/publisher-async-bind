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
    
    func increase(_ int: Int, shouldFail: Bool = false) async throws -> Int {
        let cancelled: @Sendable () -> Void = {
            self.didCacncelled?()
        }
        
        let increaseAction: () async throws -> Int = {
            try await Task.sleep(nanoseconds: 100)
            guard shouldFail == false
            else {
                throw RuntimeError()
            }
            return int + 1
        }
        return try await withTaskCancellationHandler(operation: increaseAction, onCancel: cancelled)
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
        self.wait(for: [expect], timeout: 0.001)
            
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
        self.wait(for: [expect], timeout: 0.001)
        
        // then
        XCTAssertNotNil(failure)
    }
    
//    func test_runExpression_cancelled() {
//        // given
//        let expect = expectation(description: "run expression will cancel")
//        expect.assertForOverFulfill = false
//
//        self.didCacncelled = {
//            expect.fulfill()
//        }
//
//        // when
//        let cancellable = self.subject
//            .flatMap { int async throws -> Int? in
//                var result: Int = int
//                for _ in 0..<100 {
//                    result = try await self.increase(result)
//                }
//                return result
//            }
//            .sink(receiveCompletion: { _ in }, receiveValue: { _ in })
//        self.subject.send(1)
//        DispatchQueue.main.asyncAfter(deadline: .now() + 0.001) {
//            cancellable.cancel()
//        }
//
//        // then
//        self.wait(for: [expect], timeout: 0.1)
//    }
}
