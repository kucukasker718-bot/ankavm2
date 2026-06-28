import os
import subprocess
import tempfile
import uuid

# Basit bir Autounattend.xml şablonu. (Administrator şifresini set eder)
AUTOUNATTEND_XML_TEMPLATE = """<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
    <settings pass="oobeSystem">
        <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <UserAccounts>
                <AdministratorPassword>
                    <Value>{password}</Value>
                    <PlainText>true</PlainText>
                </AdministratorPassword>
            </UserAccounts>
            <AutoLogon>
                <Password>
                    <Value>{password}</Value>
                    <PlainText>true</PlainText>
                </Password>
                <Enabled>true</Enabled>
                <LogonCount>1</LogonCount>
                <Username>Administrator</Username>
            </AutoLogon>
            <OOBE>
                <HideEULAPage>true</HideEULAPage>
                <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
                <NetworkLocation>Work</NetworkLocation>
                <ProtectYourPC>1</ProtectYourPC>
                <SkipMachineOOBE>true</SkipMachineOOBE>
                <SkipUserOOBE>true</SkipUserOOBE>
            </OOBE>
        </component>
    </settings>
</unattend>
"""

def generate_windows_autounattend_iso(password: str, output_dir: str = "/var/lib/libvirt/images") -> str:
    """
    Şifreyi gömerek Autounattend.xml oluşturur ve genisoimage ile bir sanal ISO'ya paketler.
    Bu ISO daha sonra virt-install ile cdrom/floppy olarak Windows'a bağlanır.
    """
    # Benzersiz isim oluştur
    uid = str(uuid.uuid4())[:8]
    iso_name = f"unattend_{uid}.iso"
    iso_path = os.path.join(output_dir, iso_name)
    
    # Geçici bir dizinde xml oluştur ve iso'ya bas
    with tempfile.TemporaryDirectory() as tmpdir:
        xml_path = os.path.join(tmpdir, "Autounattend.xml")
        xml_content = AUTOUNATTEND_XML_TEMPLATE.format(password=password)
        
        with open(xml_path, "w", encoding="utf-8") as f:
            f.write(xml_content)
            
        # genisoimage kullanarak ISO oluştur
        try:
            subprocess.run(
                ["genisoimage", "-J", "-r", "-V", "OEMDRV", "-o", iso_path, tmpdir],
                check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
            )
            return iso_path
        except FileNotFoundError:
            # Fallback if genisoimage is missing, just use mkisofs if exists
            try:
                subprocess.run(
                    ["mkisofs", "-J", "-r", "-V", "OEMDRV", "-o", iso_path, tmpdir],
                    check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
                )
                return iso_path
            except Exception as e:
                print(f"[Windows AutoUnattend] ISO oluşturma hatası: {e}")
                return ""
        except Exception as e:
            print(f"[Windows AutoUnattend] ISO oluşturma hatası: {e}")
            return ""

