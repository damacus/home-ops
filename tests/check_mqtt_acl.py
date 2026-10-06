import subprocess, tempfile, shutil, time
from pathlib import Path
IMAGE="public.ecr.aws/docker/library/eclipse-mosquitto:2.0.22"
APP=Path(__file__).resolve().parents[1] / "kubernetes/apps/home-automation/mosquitto/app"
def run(*args, check=True):
    result=subprocess.run(["rtk","proxy","docker",*args],capture_output=True,text=True)
    if check and result.returncode: raise RuntimeError(result.stdout + result.stderr)
    return result
with tempfile.TemporaryDirectory(prefix="mqtt-auth-test-") as temporary:
    directory=Path(temporary); directory.chmod(0o755)
    (directory/"mosquitto.conf").write_text((APP/"mosquitto-final.conf").read_text().replace("persistence true", "persistence false").replace("/mosquitto/auth/password_file","/test/password_file").replace("/mosquitto/config/acl.conf","/test/acl.conf"))
    shutil.copyfile(APP/"acl.conf",directory/"acl.conf")
    for index,user in enumerate(("homeassistant","frigate","growhat")):
        flags=["-c","-b"] if index==0 else ["-b"]
        run("run","--rm","--entrypoint","mosquitto_passwd","-v",str(directory)+":/test",IMAGE,*flags,"/test/password_file",user,"isolated-test-password")
    (directory/"password_file").chmod(0o644)
    container=run("run","-d","--rm","--entrypoint","mosquitto","-v",str(directory)+":/test:ro",IMAGE,"-c","/test/mosquitto.conf").stdout.strip()
    try:
        for attempt in range(30):
            ready=run("exec",container,"mosquitto_pub","-h","127.0.0.1","-u","frigate","-P","isolated-test-password","-t","frigate/test","-m","test","-V","5","-q","1","-d",check=False)
            if ready.returncode==0: break
            time.sleep(0.2)
        assert ready.returncode==0, "Authenticated Frigate publish failed"
        cases=[("anonymous",[],"frigate/test",False),("wrong password",["-u","frigate","-P","wrong-test-password"],"frigate/test",False),("Frigate own topic",["-u","frigate","-P","isolated-test-password"],"frigate/test",True),("Frigate cannot command Growhat",["-u","frigate","-P","isolated-test-password"],"growhat/grow_pi_zero_w/pump/set",False),("Growhat telemetry",["-u","growhat","-P","isolated-test-password"],"growhat/grow_pi_zero_w/1/state",True),("Growhat discovery",["-u","growhat","-P","isolated-test-password"],"homeassistant/sensor/grow_pi_zero_w_1/frequency/config",True),("Growhat cannot write Frigate",["-u","growhat","-P","isolated-test-password"],"frigate/test",False),("HA command",["-u","homeassistant","-P","isolated-test-password"],"growhat/grow_pi_zero_w/display/set",True)]
        for label,credentials,topic,allowed in cases:
            result=run("exec",container,"mosquitto_pub","-h","127.0.0.1",*credentials,"-t",topic,"-m","isolated-test","-V","5","-q","1","-d",check=False)
            assert (result.returncode==0 and "RC:135" not in result.stdout and "Not authorized" not in (result.stdout+result.stderr))==allowed, label+": unexpected publish result\n"+result.stdout+result.stderr
            print("PASS:",label)
    finally:
        run("stop",container,check=False)
