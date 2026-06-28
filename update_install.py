import os
import re

install_file = "c:/Users/Administrator/Desktop/ankavm2-main/scripts/install.sh"
with open(install_file, "r", encoding="utf-8") as f:
    content = f.read()

def replace_block(filepath, varname):
    global content
    try:
        with open(filepath, "r", encoding="utf-8") as src:
            file_data = src.read()
    except Exception as e:
        print(f"Skipping {filepath}, error: {e}")
        return

    pattern = re.compile(rf"(cat << '_ANKAVM_EOF_' > /opt/ankavm/{varname}\n).*?(\n_ANKAVM_EOF_)", re.DOTALL)
    
    if pattern.search(content):
        # Using lambda so that the return string is NOT parsed for escape sequences like \x or \n
        content = pattern.sub(lambda m: f"{m.group(1)}{file_data}{m.group(2)}", content)
        print(f"Updated {varname} in install.sh")
    else:
        # If it doesn't exist, we append it right before the "# 5. Deploy systemd service" block
        insert_marker = "# 5. Deploy systemd service"
        print(f"Adding new file {varname} to install.sh")
        replacement = f"cat << '_ANKAVM_EOF_' > /opt/ankavm/{varname}\n{file_data}\n_ANKAVM_EOF_"
        content = content.replace(insert_marker, f"# Write {varname}\n{replacement}\n\n{insert_marker}")

# Files to update
replace_block("c:/Users/Administrator/Desktop/ankavm2-main/backend/main.py", "backend/main.py")
replace_block("c:/Users/Administrator/Desktop/ankavm2-main/backend/models.py", "backend/models.py")
replace_block("c:/Users/Administrator/Desktop/ankavm2-main/frontend/app.js", "frontend/app.js")
replace_block("c:/Users/Administrator/Desktop/ankavm2-main/frontend/index.html", "frontend/index.html")

# New files
replace_block("c:/Users/Administrator/Desktop/ankavm2-main/backend/routers_vcenter.py", "backend/routers_vcenter.py")
replace_block("c:/Users/Administrator/Desktop/ankavm2-main/backend/routers_images.py", "backend/routers_images.py")
replace_block("c:/Users/Administrator/Desktop/ankavm2-main/backend/routers_wisecp.py", "backend/routers_wisecp.py")

# Also add pyvmomi to requirements.txt
req_pattern = re.compile(r"(cat << '_ANKAVM_EOF_' > /opt/ankavm/backend/requirements\.txt.*?)(_ANKAVM_EOF_)", re.DOTALL)
def add_req(match):
    req_body = match.group(1)
    if "pyvmomi" not in req_body:
        req_body += "pyvmomi>=8.0.1.0.2\n"
    if "httpx" not in req_body:
        req_body += "httpx>=0.27.0\n"
    if "sqlalchemy" not in req_body:
        req_body += "sqlalchemy>=2.0.0\n"
    return req_body + match.group(2)

content = req_pattern.sub(add_req, content)

with open(install_file, "w", encoding="utf-8", newline='\n') as f:
    f.write(content)

print("install.sh updated successfully!")
