"""CI uses private temporary trust and a local HTTPS origin on an isolated runner."""
import contextlib
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
import os, json, ssl, subprocess, sys, tempfile, threading, time
from pathlib import Path
from PIL import Image, ImageChops
from browser_compare import compare

root=Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory() as temp:
    work=Path(temp)
    for path in sys.argv[1:]:
        (work/Path(path).name).write_bytes(Path(path).read_bytes())
    subprocess.run(["openssl","req","-x509","-newkey","rsa:2048","-nodes","-days","1",
                    "-subj","/CN=origin.test","-addext","subjectAltName=DNS:origin.test",
                    "-keyout",str(work/"key"),"-out",str(work/"cert")],check=True,stderr=subprocess.DEVNULL)
    class Handler(SimpleHTTPRequestHandler):
        def __init__(self,*a,**kw): super().__init__(*a,directory=str(work),**kw)
    origin=ThreadingHTTPServer(("127.0.0.1",18243), Handler)
    tls=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    tls.load_cert_chain(work/"cert",work/"key")
    origin.socket=tls.wrap_socket(origin.socket,server_side=True)
    threading.Thread(target=origin.serve_forever,daemon=True).start()
    web=ThreadingHTTPServer(("127.0.0.1",18280), Handler)
    threading.Thread(target=web.serve_forever,daemon=True).start()
    conf=work/"ca"
    conf.mkdir()
    ready=work/"ready"
    env=dict(os.environ,FILTER_DOMAINS=json.dumps(["origin.test"]),FILTER_READY=str(ready),
             FILTER_WORKER=str(root/"dist/Mac Proxy Filter.app/Contents/MacOS/MaskWorker"))
    proxy=subprocess.Popen(["mitmdump","--quiet","--listen-host","127.0.0.1","-p","17862",
        "--set","connection_strategy=lazy","--set","confdir="+str(conf),
        "--set","ssl_verify_upstream_trusted_ca="+str(work/"cert"),
        "-s",str(root/"proxy/filter.py")],env=env)
    try:
        for _ in range(120):
            if ready.exists(): break
            if proxy.poll() is not None: raise RuntimeError("Proxy exited during startup")
            time.sleep(.1)
        assert ready.exists()
        curl=["curl","--silent","--show-error","--noproxy","","--proxy","http://127.0.0.1:17862",
              "--max-time","30","--cacert",str(conf/"mitmproxy-ca-cert.pem")]
        for name in ["coffee.png","portrait.png"]:
            out=work/("out-"+name)
            subprocess.run(curl+["--fail","https://origin.test:18243/"+name,"-o",str(out)],check=True)
            if name=="coffee.png":
                assert out.read_bytes()==(work/name).read_bytes(),"Clear image changed"
            else:
                a=Image.open(work/name).convert("RGB")
                b=Image.open(out).convert("RGB")
                assert a.size==b.size
                delta=ImageChops.difference(a,b)
                assert delta.crop((190,65,255,140)).getbbox(),"Portrait face unchanged"
                assert delta.getpixel((2,2))==(0,0,0),"Corner changed"
        veto=subprocess.run(curl+["--fail","https://elsewhere.test/"],capture_output=True)
        assert veto.returncode and b"403" in veto.stderr,veto.stderr
        compare(work)
        print("HTTPS portrait masked, clear bytes preserved, unlisted CONNECT refused")
    finally:
        proxy.terminate()
        proxy.wait(timeout=10)
        origin.shutdown()
        web.shutdown()
