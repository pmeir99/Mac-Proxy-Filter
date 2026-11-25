"""CI uses private temporary trust and a local HTTPS origin on an isolated runner."""
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
import os, json, ssl, subprocess, sys, tempfile, threading, time
from pathlib import Path
from PIL import Image, ImageChops
from browser_compare import compare

with tempfile.TemporaryDirectory() as temp:
    work=Path(temp)/"public"
    work.mkdir()
    state=Path(temp)/"private"
    state.mkdir(mode=0o700)
    for path in sys.argv[1:]:
        (work/Path(path).name).write_bytes(Path(path).read_bytes())
    cutout=Image.open(work/"portrait.png").convert("RGBA")
    alpha=Image.new("L",cutout.size,255)
    for opacity,box in [(0,(160,230,210,310)),(128,(270,240,290,305))]:
        alpha.paste(opacity,box)
    cutout.putalpha(alpha)
    cutout.save(work/"cutout.png")
    config = state/"openssl.cnf"
    config.write_text("[req]\ndistinguished_name=dn\nx509_extensions=extensions\n"
                      "[dn]\n[extensions]\nbasicConstraints=critical,CA:TRUE\n"
                      "subjectAltName=DNS:origin.test\n")
    subprocess.run(["/usr/bin/openssl","req","-x509","-newkey","rsa:2048","-nodes","-days","1",
                    "-subj","/CN=origin.test","-config",str(config),
                    "-keyout",str(state/"key"),"-out",str(state/"cert")],check=True,stderr=subprocess.DEVNULL)
    class Handler(SimpleHTTPRequestHandler):
        def __init__(self,*a,**kw): super().__init__(*a,directory=str(work),**kw)
    origin=ThreadingHTTPServer(("127.0.0.1",18243), Handler)
    tls=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    tls.load_cert_chain(state/"cert",state/"key")
    origin.socket=tls.wrap_socket(origin.socket,server_side=True)
    threading.Thread(target=origin.serve_forever,daemon=True).start()
    web=ThreadingHTTPServer(("127.0.0.1",18280), Handler)
    threading.Thread(target=web.serve_forever,daemon=True).start()
    conf=state/"ca"
    conf.mkdir()
    ready=state/"ready"
    bundle=Path(os.environ["FILTER_TEST_APP"]).resolve(strict=True)
    executables=bundle/"Contents/MacOS"
    engine=bundle/"Contents/Helpers/mitmproxy.app/Contents/MacOS/mitmdump"
    env=dict(os.environ,PYTHONDONTWRITEBYTECODE="1",FILTER_DOMAINS=json.dumps(["origin.test"]),FILTER_READY=str(ready),
             FILTER_WORKER=str(executables/"MaskWorker"))
    env.update(PATH="/usr/bin:/bin:/usr/sbin:/sbin")
    env.pop("PYTHONHOME",None)
    env.pop("PYTHONPATH",None)
    subprocess.run([engine,"--version"],env=env,check=True)
    proxy=subprocess.Popen([engine,"--quiet","--allow-hosts",r"(?i)^(?:origin\.test)\.?:[0-9]+$","--set","onboarding=false","--listen-host","127.0.0.1","-p","17862",
        "--set","connection_strategy=lazy","--set","confdir="+str(conf),
        "--set","ssl_verify_upstream_trusted_ca="+str(state/"cert"),
        "-s",str(bundle/"Contents/Resources/filter.py")],env=env)
    try:
        for _ in range(300):
            if ready.exists(): break
            if proxy.poll() is not None: raise RuntimeError("Proxy exited during startup")
            time.sleep(.1)
        assert ready.exists()
        curl=["curl","--silent","--show-error","--noproxy","","--proxy","http://127.0.0.1:17862",
              "--max-time","30","--cacert",str(conf/"mitmproxy-ca-cert.pem")]
        for name in ["coffee.png","portrait.png","cutout.png"]:
            out=work/("out-"+name)
            started=time.perf_counter()
            subprocess.run(curl+["--fail","https://origin.test:18243/"+name,"-o",str(out)],check=True)
            print(f"{name}: end-to-end {(time.perf_counter()-started)*1000:.0f} ms",flush=True)
            if name=="coffee.png":
                assert out.read_bytes()==(work/name).read_bytes(),"Clear image changed"
            else:
                if name=="cutout.png":
                    actual_alpha=Image.open(out).convert("RGBA").getchannel("A")
                    assert ImageChops.difference(alpha,actual_alpha).getbbox() is None, "Alpha changed"
                a=Image.open(work/name).convert("RGB")
                b=Image.open(out).convert("RGB")
                assert a.size==b.size
                delta=ImageChops.difference(a,b)
                assert delta.crop((190,65,255,140)).getbbox(),"Portrait face unchanged"
                assert delta.getpixel((2,2))==(0,0,0),"Corner changed"
        veto=subprocess.run(curl+["--fail","https://elsewhere.test/"],capture_output=True)
        assert veto.returncode and b"403" in veto.stderr,veto.stderr
        compare(work)
        subprocess.run(["codesign","--verify","--deep","--strict",str(bundle)], check=True)
        print("HTTPS portrait masked, clear bytes preserved, unlisted CONNECT refused")
    finally:
        proxy.terminate()
        proxy.wait(timeout=10)
        origin.shutdown()
        web.shutdown()
