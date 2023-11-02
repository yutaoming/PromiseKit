import Dispatch

// [问题] 为什么这里要叫做密封剂呢
enum Sealant<R> {
    case pending(Handlers<R>)
    case resolved(R)
}

// 本质是一个闭包数组
final class Handlers<R> {
    var bodies: [(R) -> Void] = []
    func append(_ item: @escaping(R) -> Void) { bodies.append(item) }
}

/// - Remark: not protocol ∵ http://www.russbishop.net/swift-associated-types-cont
// 一个基类，定义了三个方法，类似 protocol 的概念
// [问题] 不过为什么没有用 protocol 呢？
class Box<T> {
    // 所以这里的 inspect 就是指 inspect Box 的状态
    // 查询当前 Box 的状态
    func inspect() -> Sealant<T> { fatalError() }
    // 暴露出当前 Box 的状态，外部根据 Box 的状态来做一些事情
    func inspect(_: (Sealant<T>) -> Void) { fatalError() }
    // 接受一个 T
    func seal(_: T) {}
}

// 一个封好的盒子，里面有一个值，状态已经 resolved 了，并且不能修改。
final class SealedBox<T>: Box<T> {
    let value: T

    init(value: T) {
        self.value = value
    }

    override func inspect() -> Sealant<T> {
        return .resolved(value)
    }
}


class EmptyBox<T>: Box<T> {
    // 表示当前 Box 的状态
    private var sealant = Sealant<T>.pending(.init())
    // [问题] 一个并行队列，为什么这里要用队列呢？
    private let barrier = DispatchQueue(label: "org.promisekit.barrier", attributes: .concurrent)

    override func seal(_ value: T) {
        var handlers: Handlers<T>!
        barrier.sync(flags: .barrier) {
            guard case .pending(let _handlers) = self.sealant else {
                return  // already fulfilled!
            }
            handlers = _handlers
            self.sealant = .resolved(value)
        }

        //FIXME we are resolved so should `pipe(to:)` be called at this instant, “thens are called in order” would be invalid
        //NOTE we don’t do this in the above `sync` because that could potentially deadlock
        //THOUGH since `then` etc. typically invoke after a run-loop cycle, this issue is somewhat less severe

        if let handlers = handlers {
            handlers.bodies.forEach{ $0(value) }
        }

        //TODO solution is an unfortunate third state “sealed” where then's get added
        // to a separate handler pool for that state
        // any other solution has potential races
    }

    override func inspect() -> Sealant<T> {
        var rv: Sealant<T>!
        barrier.sync {
            rv = self.sealant
        }
        return rv
    }

    // 本质上就是读取 Box 的状态，再做一些操作
    override func inspect(_ body: (Sealant<T>) -> Void) {
        var sealed = false
        barrier.sync(flags: .barrier) {
            switch sealant {
            case .pending:
                // body will append to handlers, so we must stay barrier’d
                body(sealant)
            case .resolved:
                sealed = true
            }
        }
        if sealed {
            // we do this outside the barrier to prevent potential deadlocks
            // it's safe because we never transition away from this state
            body(sealant)
        }
    }
}


extension Optional where Wrapped: DispatchQueue {
    @inline(__always)
    func async(flags: DispatchWorkItemFlags?, _ body: @escaping() -> Void) {
        switch self {
        case .none:
            body()
        case .some(let q):
            if let flags = flags {
                q.async(flags: flags, execute: body)
            } else {
                q.async(execute: body)
            }
        }
    }
}
