import subprocess
import os
import yaml
import argparse
import shutil
from dotenv import load_dotenv

# ----------------------------------------
# - Safely restore repository
# ----------------------------------------

def is_tool(name):
    """Check whether `name` is on PATH and marked as executable."""

    return shutil.which(name) is not None

def safe_restore():

    os.system(f"git restore --staged rtl/")
    os.system(f"git restore --staged docs/")
    os.system(f"git restore --staged verification/")

    os.system(f"git checkout -- rtl/")
    os.system(f"git checkout -- docs/")
    os.system(f"git checkout -- verification/")
    
def safe_library(external = []):

    # Remove external links
    for file in external:
        os.remove(file)

# ----------------------------------------
# - Encapsulates docker process
# ----------------------------------------

class Harness():

    def format_compose(self, composer : str = "docker-compose.yml"):

            cwd      = os.getcwd()
            volumes  = [ f'-v "{cwd}/{vol}:/code/{vol}"' for vol in ["docs", "rtl", "verification", "rundir"] ]
            volumes.extend([f'-v "{cwd}/harness/lib:/pylib:ro"'])
            volumes.extend([f'-v "{cwd}/harness/subj:/pysubj:ro"'])
            volumes  = " ".join(volumes)

            # Retriving information from system to Docker.
            key      = os.getenv("OPENAI_USER_KEY")

            if (key != "") and (key != None):
                env = f"--env OPENAI_USER_KEY={key}"
            else:
                env = ""

            cmd = f"docker compose -f {composer} run {volumes} --rm --build -w /code/rundir"
            print(f"{cmd}")

            return f"{cmd} {env}"

    def evaluate(self, id : int, checkout : bool = True):

        env_path = os.path.join('harness', f'{id}')
        print(f"Searching for .env file in : {env_path}")

        # Load correct .env file
        load_dotenv(os.path.join(env_path, 'src', '.env'))

        # Identify services from YAML File
        with open(os.path.join(env_path, 'docker-compose.yml'), 'r') as ymlfile:
            docker_config = yaml.safe_load(ymlfile)

        # Library identification
        lib_path = os.path.join('library', 'export.yml')
        lib_maps = []
        if os.path.exists(lib_path):

            with open(lib_path) as ymlfile:
                library_config = yaml.safe_load(ymlfile)
                
            for issue in library_config['export']:

                if id in issue:

                    for mapping in issue[id][0]['context']:

                        # Mapping file to corresponding library file
                        key   = list(mapping.keys())[0]
                        value = list(mapping.values())[0]

                        lib_maps.append(value)

                        # Copy files
                        print(f"Copying file from external library: {key} to {value}")
                        shutil.copy(key, value)

                else:
                    print(f"No external library link for issue {id}.")

        # Access Hash Environment Variable
        hash = os.getenv("HASH")

        if is_tool('docker'):
            print("Python was able to locate docker in $PATH.")
        else:
            raise ValueError("Unable to locate docker in $PATH.")

        if is_tool('git'):
            print("Python was able to locate git in $PATH.")
        else:
            raise ValueError("Unable to locate git in $PATH.")

        if hash != None and checkout:

            os.system(f"git checkout {hash} docs/")
            os.system(f"git checkout {hash} rtl/")
            os.system(f"git checkout {hash} verification/")

            print(f"Checkout-out rtl, docs and verification folders to {hash}")

        elif not checkout:
            print(f"Using available files in rtl, docs and verification folders.")
        else:
            raise ValueError("Unable to identify git hash.")

        error = 0

        # ----------------------------------------
        # - Run Docker YML
        # ----------------------------------------

        # Identify services
        services = docker_config['services'].keys()

        try:

            # Run all services for the desired data point
            for i in services:

                # ----------------------------------------
                # - Image Update Process
                # ----------------------------------------

                print(f"Updating docker image for service: {i}...")
                try:
                    if 'image' in docker_config['services'][i]:
                        upd = f"docker pull {docker_config['services'][i]['image']}"
                    else:
                        upd = f"docker compose -f harness/{id}/docker-compose.yml build --pull --no-cache {i}"


                    print(upd)
                    subprocess.run(upd, shell=True)

                except:
                    print(f"Could not update the image for service: {i}.")

                # ----------------------------------------
                # - Service Start
                # ----------------------------------------

                print(f"Starting service: {i}...")
                cmd = self.format_compose(f"harness/{id}/docker-compose.yml")
                cmd = f"{cmd} {i}"

                result = subprocess.run(cmd, shell=True)
                error += result.returncode

        except:
            if checkout:
                safe_restore()

            # Safely restore library files
            safe_library(lib_maps)
            raise ValueError(f"Unable to safely run all docker tests.")

        # ----------------------------------------
        # - Restore git environment
        # ----------------------------------------

        if checkout:
            print(f"Restoring to previous context...")
            safe_restore()

        # Safely restore library files
        safe_library(lib_maps)

        # ----------------------------------------
        # - Final Report
        # ----------------------------------------

        if (error == 0):
            print(f"Success! All harness ran succesfully for data point {id}!")
        else:
            raise ValueError(f"Error! At least one harness service failed for data point {id}!")

        return (error != 0)

# ----------------------------------------
# - Command Line Execution
# ----------------------------------------

if __name__ == "__main__":

    # Parse Creation
    parser = argparse.ArgumentParser(description="Exemplo de uso do argparse")
    parser.add_argument("-n", "--no-checkout", action=argparse.BooleanOptionalAction, help="Allow test to execute without checking-out to specified git HASH.")

    # Adding arguments
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("-i", "--id",       type=int, help="ID of the Issue related to the Harness Data Point.")
    group.add_argument("--all", action="store_true", help="Select all of the harness to run")

    # Arg Parsing
    args = parser.parse_args()
    test = Harness()
    chkt = True if args.no_checkout == None else False

    if args.id is not None:

        if test.evaluate(args.id, chkt):
            raise ValueError(f"Error in execution of data point {args.id}")

    elif args.all:
        items = os.listdir('harness/')
        ids   = [item for item in items if os.path.isdir(os.path.join('harness', item)) and item.isnumeric()]
        error = 0

        for id in ids:
            error += test.evaluate(id, chkt)
