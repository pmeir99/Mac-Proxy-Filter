"""CI uses private temporary trust and a local HTTPS origin on an isolated runner."""
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from io import BytesIO
from zipfile import ZipFile
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
    env=dict(os.environ,FILTER_TOKEN="ci-test",FILTER_CAPTURE="1",PYTHONDONTWRITEBYTECODE="1",FILTER_DOMAINS=json.dumps(["origin.test"]),FILTER_READY=str(ready),
             FILTER_WORKER=str(executables/"MaskWorker"))
    env.update(PATH="/usr/bin:/bin:/usr/sbin:/sbin")
    env.pop("PYTHONHOME",None)
    env.pop("PYTHONPATH",None)
    subprocess.run([engine,"--version"],env=env,check=True)
    if env.get("FILTER_ALL") == "1":
        env["FILTER_DOMAINS"] = "[]"
        env["FILTER_EXCLUDED"] = json.dumps(["outside.test", "elsewhere.test"])
    if env.get("FILTER_ALL") == "1":
        # Exercise the relaxed shape independently of the HTTP comparison.
        source=(work/"portrait.png").read_bytes()
        def covered(margin):
            frame=subprocess.check_output([env["FILTER_WORKER"]],input=len(source).to_bytes(4,"big")+source,
                env=dict(env,FILTER_STYLE="Cover", FILTER_COLOR="FD019C", FILTER_SHAPE="Rectangle", FILTER_MARGIN=margin))
            assert int.from_bytes(frame[:4],"big")==len(frame)-4
            image=Image.open(BytesIO(frame[4:])).convert("RGB")
            return sum(r>245 and g<8 and abs(b-156)<8 for r,g,b in image.getdata())
        tight=covered("0")
        assert tight>10000 and covered("0.1")>tight, "Rectangle or configurable padding failed"
    proxy=subprocess.Popen([engine,"--quiet","--set","onboarding=false","--listen-host","127.0.0.1","-p","17862",
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
        # A fresh Mac must reject our unapproved root; the positive tests below
        # subsequently trust only this fixture's CA for their own process.
        untrusted = subprocess.run(["/usr/bin/curl","--disable","--silent","--head","--max-time","15",
            "--proxy","http://127.0.0.1:17862","--noproxy","","https://origin.test:18243/coffee.png"],
            env={"PATH":"/usr/bin:/bin"}, capture_output=True)
        assert untrusted.returncode == 60, ("Untrusted test CA was not rejected", untrusted.returncode)
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
        for edge in (64,128):
            for name in ("portrait","coffee"):
                thumb=Image.open(work/(name+".png")).convert("RGB")
                thumb.thumbnail((edge,edge))
                path=work/f"{name}-{edge}.jpg"
                thumb.save(path,quality=75)
                served=subprocess.check_output(curl+["--fail","https://origin.test:18243/"+path.name])
                assert Image.open(BytesIO(served)).size==thumb.size
                assert (served==path.read_bytes())==(name=="coffee"), path.name
        diagnostic=["curl","--fail","--silent","--noproxy","*","-H","Authorization: Bearer ci-test"]
        export_url="http://127.0.0.1:17861/export"
        assert subprocess.run(["curl","--fail","--silent","--noproxy","*",export_url],capture_output=True).returncode != 0
        with ZipFile(BytesIO(subprocess.check_output(diagnostic+[export_url+"?site=origin.test"]))) as report:
            rows=json.loads(report.read("manifest.json"))
            assert any(r["verdict"]=="Masked" and report.read(r["after"])==(work/"out-portrait.png").read_bytes()
                       and report.read(r["before"])==(work/"portrait.png").read_bytes() for r in rows)
        with ZipFile(BytesIO(subprocess.check_output(diagnostic+[export_url+"?site=unrelated.test"]))) as report:
            assert json.loads(report.read("manifest.json"))==[]
        compare(work)
        stats=json.loads(subprocess.check_output(["curl","--noproxy","*","--silent","http://127.0.0.1:17861/status"]))
        assert stats["scanned"] >= 3 and stats["masked"] >= 2, stats
        subprocess.run(["codesign","--verify","--deep","--strict",str(bundle)], check=True)
        print("HTTPS portrait masked, clear bytes preserved, unlisted CONNECT refused")
    finally:
        proxy.terminate()
        proxy.wait(timeout=10)
        origin.shutdown()
        web.shutdown()
