#!/usr/bin/env python3
"""Writes the audit list used by dzn_audit: one "EXTENSION vkCommand" line per
device command that dzn advertises (core commands are listed as CORE_1_x).

usage: MESA_SRC=/path/to/mesa-25.2.8 python3 gen_cmds.py OUTPUT
       VK_XML=/path/to/vk.xml (default /usr/share/vulkan/registry/vk.xml)
"""
import os
import re
import sys
import xml.etree.ElementTree as ET

mesa = os.environ.get('MESA_SRC', '.')
vk_xml = os.environ.get('VK_XML', '/usr/share/vulkan/registry/vk.xml')
out_path = sys.argv[1] if len(sys.argv) > 1 else 'audit_cmds.txt'

vk = ET.parse(vk_xml).getroot()
src = open(os.path.join(mesa, 'src/microsoft/vulkan/dzn_device.c')).read()
m = re.search(r'pdev->vk\.supported_extensions = \(struct vk_device_extension_table\) \{(.*?)\n   \};', src, re.S)
exts = set()
skip = 0
for line in m.group(1).splitlines():
    s = line.strip()
    if s.startswith('#ifdef _WIN32') or s.startswith('#ifndef __linux__'):
        skip += 1
        continue
    if s.startswith('#if') and skip:
        skip += 1
        continue
    if s.startswith('#endif') and skip:
        skip -= 1
        continue
    if s.startswith('#else') and skip == 1:
        skip = 0
        continue
    if skip:
        continue
    mm = re.match(r'\.((?:KHR|EXT|MSFT|VALVE|NV|GOOGLE|IMG|AMD|ARM|QCOM|ANDROID)_\w+)\s*=', s)
    if mm:
        exts.add('VK_' + mm.group(1))

cmds = {}
for c in vk.iter('command'):
    nm = c.find('proto/name')
    if nm is None:
        continue
    p = c.find('param')
    t = p.find('type').text if p is not None and p.find('type') is not None else ''
    cmds[nm.text] = t in ('VkDevice', 'VkQueue', 'VkCommandBuffer')

out = []
for e in vk.iter('extension'):
    en = e.get('name')
    if en not in exts:
        continue
    for req in e.findall('require'):
        for c in req.findall('command'):
            n = c.get('name')
            if cmds.get(n):
                out.append((en, n))
for feat in vk.iter('feature'):
    fn = feat.get('name')
    if fn not in ('VK_VERSION_1_1', 'VK_VERSION_1_2', 'VK_VERSION_1_3'):
        continue
    for req in feat.findall('require'):
        for c in req.findall('command'):
            n = c.get('name')
            if cmds.get(n):
                out.append(('CORE_' + fn[-3:], n))

with open(out_path, 'w') as f:
    for en, n in out:
        f.write(en + ' ' + n + '\n')
print('advertised extensions parsed:', len(exts), 'device commands written:', len(out))