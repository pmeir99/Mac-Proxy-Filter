"""Manual public-CDN compatibility probe. Uses a temporary CA, scoped only to curl."""
import os, subprocess, tempfile, json, time
from pathlib import Path
from urllib.parse import urlsplit
from PIL import Image
from io import BytesIO

urls=[
    "https://pisces.bbystatic.com/image2/BestBuy_US/images/products/6505/6505727_rd.jpg;maxHeight=256;maxWidth=384",
    "https://images.thdstatic.com/productImages/aef2e809-5c73-488f-ae91-46706f3018de/svn/stark-claw-hammers-15000-64_65.jpg"
]
login_url = "https://my.ny.gov/LoginV4/login.xhtml"
app=Path(os.environ["FILTER_TEST_APP"])/"Contents"
with tempfile.TemporaryDirectory() as d:
    folder=Path(d)
    env=dict(os.environ,FILTER_DOMAINS=json.dumps([urlsplit(u).hostname for u in [*urls,login_url]]),
             FILTER_TOKEN="public-test",FILTER_CAPTURE="1",FILTER_READY=str(folder/"ready"),
             FILTER_WORKER=str(app/"MacOS/MaskWorker"))
    proc=subprocess.Popen([app/"Helpers/mitmproxy.app/Contents/MacOS/mitmdump","-q","--listen-host","127.0.0.1","-p","17862",
               "--set","confdir="+d,"-s",app/"Resources/filter.py"],env=env)
    try:
        for _ in range(300):
            if (folder/"ready").exists(): break
            if proc.poll() is not None: raise RuntimeError("engine exited")
            time.sleep(.1)
        for url in urls:
            try:
                raw=subprocess.check_output(["curl","--silent","--show-error","--fail","--max-time","25","--noproxy","","--proxy",
                    "http://127.0.0.1:17862","--cacert",str(folder/"mitmproxy-ca-cert.pem"),"-H","Sec-Fetch-Dest: image",url])
                image=Image.open(BytesIO(raw));image.load()
                print("Live CDN returned a decoded image",urlsplit(url).hostname,image.size,flush=True)
            except Exception as err:
                print("::warning::Live CDN probe inconclusive or blocked: "+str(err),flush=True)
        # Fetch only the public sign-in page, without redirects, cookies or credentials.
        for label, route in (("direct",["--noproxy","*"]), ("filtered",["--noproxy","","--proxy",
                "http://127.0.0.1:17862","--cacert",str(folder/"mitmproxy-ca-cert.pem")])):
            result = subprocess.run(["curl","--disable","--silent","--show-error","--max-time","25",*route,
                "-o",os.devnull,"-w","%{http_code}",login_url],capture_output=True,text=True)
            print("Public login probe",label,"HTTP",result.stdout,"curl",result.returncode,result.stderr[:200],flush=True)
        rows=json.loads(subprocess.check_output(["curl","--silent","--noproxy","*","-H","Authorization: Bearer public-test","http://127.0.0.1:17861/events"]))
        for row in rows: print("CDN decision",row["host"],row["verdict"],row.get("origin"),row.get("failure",""),flush=True)
    finally:
        proc.terminate();proc.wait(timeout=15)
