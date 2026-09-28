import Foundation
import JavaScriptCore
import CryptoKit
import Darwin

final class Execution: NSObject, RuntimeProtocol {
    weak var connection: NSXPCConnection?
    let queue = DispatchQueue(label: "launcher.javascript")

    func evaluate(_ source: String, input: String, debug: Bool, withReply reply: @escaping (String) -> Void) {
        let lock = NSLock()
        var finished = false
        let finish: (String) -> Void = { output in
            lock.lock(); defer { lock.unlock() }
            guard !finished else { return }
            finished = true
            reply(output)
        }
        // This watchdog lives outside the JS thread, so even synchronous loops are bounded.
        DispatchQueue.global().asyncAfter(deadline: .now() + 15) {
            lock.lock(); let hung = !finished; lock.unlock()
            if hung { finish(jsonString(["error": "扩展执行超时，执行服务已重启。", "code": "TIMEOUT"])); _exit(124) }
        }
        queue.async { [self] in
            guard let context = JSContext() else { finish("{\"error\":\"无法创建 JavaScript 运行时\"}"); return }
            context.name = "Vectracast Extension"
            if #available(macOS 13.3, *) { context.isInspectable = debug }
            context.exceptionHandler = { _, value in
                finish(jsonString(["error": value?.toString() ?? "JavaScript error", "code": "RUNTIME_ERROR"]))
            }
            let emit: @convention(block) (String) -> Void = { output in
                if output.utf8.count > 2_000_000 { finish("{\"error\":\"扩展结果超过大小限制\"}") }
                else { finish(output) }
            }
            let sha: @convention(block) (String) -> String = { value in
                SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
            }
            let uuid: @convention(block) () -> String = { UUID().uuidString }
            let bridge: @convention(block) (String, String, Int) -> Void = { [weak self, weak context] method, payload, requestID in
                guard let self, let context else { return }
                guard payload.utf8.count < 1_000_000 else { return }
                let broker = self.connection?.remoteObjectProxyWithErrorHandler { _ in
                    self.queue.async { context.objectForKeyedSubscript("__resolve")?.call(withArguments: [requestID, "{\"error\":\"宿主连接中断\"}"]) }
                } as? BrokerProtocol
                broker?.perform(method, payload: payload) { response in
                    self.queue.async { context.objectForKeyedSubscript("__resolve")?.call(withArguments: [requestID, response]) }
                }
            }
            context.setObject(emit, forKeyedSubscript: "__emit" as NSString)
            context.setObject(sha, forKeyedSubscript: "__sha256" as NSString)
            context.setObject(uuid, forKeyedSubscript: "__uuid" as NSString)
            context.setObject(bridge, forKeyedSubscript: "__bridge" as NSString)
            context.evaluateScript("""
            var __pending = new Map(), __next = 0;
            function __rpc(method, payload) {
              return new Promise((resolve,reject)=>{const id=++__next; __pending.set(id,{resolve,reject}); __bridge(method,JSON.stringify(payload),id);});
            }
            function __resolve(id, raw) {
              const p=__pending.get(id); if(!p)return; __pending.delete(id);
              try { const data=JSON.parse(raw); if(data.error)p.reject(new Error(data.error)); else p.resolve(data.value); } catch(e){p.reject(e);}
            }
            var console = { log: function(){}, warn: function(){}, error: function(){} };
            """)
            context.evaluateScript(source, withSourceURL: URL(string: "launcher-extension://bundle/main.js"))
            context.setObject(input, forKeyedSubscript: "__input" as NSString)
            context.evaluateScript("""
            (async function(){
              try {
                const input=JSON.parse(__input);
                const command=Extension.default.commands.find(c=>c.id===input.command);
                if(!command)throw new Error('命令不存在');
                const ctx={query:input.query,rawInput:input.rawInput,filter:input.filter||"",preferences:input.preferences||{},search:input.search||{sensitivity:'medium'},
                  secrets:{get:name=>__rpc('secrets.get',{name})},
                  catalog:{list:()=>__rpc('catalog.list',{})},
                  storage:{flags:()=>__rpc('storage.flags',{})},
                  applications:{list:()=>__rpc('applications.list',{})},
                  clipboard:{history:()=>__rpc('clipboard.history',{})},
                  network:{fetch:(url,options={})=>__rpc('network.fetch',{url,...options})},
                  crypto:{sha256:__sha256,uuid:__uuid}
                };
                const batch=await command.query(ctx);
                __emit(JSON.stringify({result:batch}));
              } catch(e){__emit(JSON.stringify({error:String(e.message||e),stack:String(e.stack||'')}));}
            })();
            """)
            // Keep the JS realm alive while asynchronous broker calls are pending.
            self.queue.asyncAfter(deadline: .now() + 15) { _ = context }
        }
    }

    func probe(_ path: String, withReply reply: @escaping (String) -> Void) {
        let readDenied = (try? Data(contentsOf: URL(fileURLWithPath: path))) == nil
        let writeDenied: Bool
        do { try Data("probe".utf8).write(to: URL(fileURLWithPath: path + ".write")); writeDenied = false }
        catch { writeDenied = true }
        // A numeric loopback address tests socket authorization without DNS or Internet availability.
        // Connection refused is NOT evidence of sandboxing: only a permission error passes.
        let socketFD = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        var networkError: Int32 = 0
        if socketFD < 0 { networkError = errno }
        else {
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = UInt16(9).bigEndian
            address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
            let result = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            if result < 0 { networkError = errno }
            Darwin.close(socketFD)
        }
        reply(jsonString(["readDenied": readDenied, "writeDenied": writeDenied,
                          "networkDenied": networkError == EPERM || networkError == EACCES,
                          "networkError": networkError, "pid": getpid()]))
    }
}

final class Delegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        let execution = Execution()
        execution.connection = connection
        connection.exportedInterface = NSXPCInterface(with: RuntimeProtocol.self)
        connection.exportedObject = execution
        connection.remoteObjectInterface = NSXPCInterface(with: BrokerProtocol.self)
        connection.resume()
        return true
    }
}

let delegate = Delegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
