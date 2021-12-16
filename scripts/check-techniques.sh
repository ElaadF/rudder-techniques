#!/bin/bash
# Bundle of tests for Rudder Techniques
set -e

#Set variables
REPOSITORY_PATH=${REPOSITORY_PATH:=$(cd .. && echo $PWD)}
EXIT=0

# Check that there is no "techniques" folder at the repository root
TECHNIQUES_EXISTS=$(find ${REPOSITORY_PATH} -maxdepth 1 -type d -name "policies" | wc -l)
if [ ${TECHNIQUES_EXISTS} -ne 0 ];then
  echo "Reason: There is a 'policies' folder in the repository. Use 'techniques' instead"
  EXIT=1
fi

# Check that there are no "metadata.xml" files in each of policy folder
METADATA_EXISTS=$(find ${REPOSITORY_PATH} -type f -name "policy.xml" | wc -l)
if [ ${METADATA_EXISTS} -ne 0 ];then
  echo "Reason: There are 'policy.xml' files in the repository. Use 'metadata.xml' instead"
  EXIT=1
fi

# Check that all XML files are well-formed
if ! find ${REPOSITORY_PATH} -type f -name "*.xml" | xargs -L 1 ${REPOSITORY_PATH}/scripts/xval.pl -q
then
  echo "Reason: XML file(s) seems to be not valid in the repository."
  EXIT=1
fi

# Check that the non-existent log level "log_error" is never used
find ${REPOSITORY_PATH} -type f -name "*.st" | while read filename
do
  if grep -rHn '"log_error"' "$filename" > /dev/null
  then
    echo "Reason: illegal log level 'log_error' found in $filename. Use result_error instead"
    exit 1
  fi
done || EXIT=1

# Check that the deprecated body 'class_trigger' is never used
find ${REPOSITORY_PATH} -type f -name "*.st" | while read filename
do
  if egrep -rHn 'classes\s+=>\s+class_trigger\s*\(' "$filename" > /dev/null
  then
    echo "Reason: deprecated body 'class_trigger' found in $filename. Use kept_if_else instead"
    exit 1
  fi
done || EXIT=1

# Check that there is no use of '&&' in the techniques causing trouble with CFEngine promise generation
find ${REPOSITORY_PATH}/techniques -type f -name "*.st" | while read filename
do
  CHECK_AMPERSAND=`egrep '((\\\&&)|([^\\\]&\\\&))|(\s+&&\s+)' "$filename" | wc -l`
  if [ ${CHECK_AMPERSAND} -ne 0 ]
  then
    echo "File ${filename} contains double ampersand which could prevent Rudder to generate CFEngine promises properly"
    exit 1
  fi
done || EXIT=1

# Check that we are not using classes to detect distribution version as DistributionVersion (which does not exists)
find ${REPOSITORY_PATH}/techniques -type f -name "*.st" | while read filename
do
  CHECK_CLASS_DISTRIB=`egrep 'debian[1-9]|redhat[1-9]|centos[1-9]' "$filename" | wc -l`
  if [ ${CHECK_CLASS_DISTRIB} -ne 0 ]
  then
    echo "Reason: found invalid use of class DistributionVersion that does not exists in file ${filename}"
    exit 1
  fi
done || EXIT=1

# Check that we are not using the non-existent class cfengine_community
find ${REPOSITORY_PATH} -type f -name "*.st" -or -name "*.cf" | while read filename
do
  if egrep -q '^[^#]*cfengine_community' "${filename}"; then
    echo "Found invalid use of class cfengine_community that does not exists in file ${filename}. Use community_edition instead."
    exit 1
  fi
done || EXIT=1


# Check that techniques are written in normal ordering
if ! ${REPOSITORY_PATH}/scripts/technique-files -l -i -f '*.cf' -f '*.st' "${REPOSITORY_PATH}" | xargs ${REPOSITORY_PATH}/scripts/ordering.pl
then
  EXIT=1
fi

# Check that techniques do not contain $() (except for line containing powershell command)
${REPOSITORY_PATH}/scripts/technique-files -l -i -f '*.cf' -f '*.st' -s 'echo {}|grep -v ".ps1.st$"' "${REPOSITORY_PATH}" | while read filename
do
  if grep '$(' "${filename}" | grep -v "powershell" >/dev/null; then
    echo "The file ${filename} contains deprecated \$() syntax"
    exit 1
  fi
done || EXIT=1

# check that techniques do not use reports:
${REPOSITORY_PATH}/scripts/technique-files -l -f '*.cf' -f '*.st' "${REPOSITORY_PATH}" | egrep -v "common/1.0/(update\.|promises\.|rudder-stdlib-core\.|hooks\.)|distributePolicy/1.0/rsyslogConf\.|inventory/1.0/fusionAgent\." | while read filename
do
  if egrep '^[[:space:]]*reports:' "${filename}" >/dev/null; then
    echo "The file ${filename} uses reports: instead of rudder_common_report"
    exit 1
  fi
done || EXIT=1

# Check that we never use group "root" in perms
${REPOSITORY_PATH}/scripts/technique-files -l -i -f '*.cf' -f '*.st' "${REPOSITORY_PATH}" | while read filename
do
  if egrep -q "^[^#]*perms\s*=>\s*mog\([^,]+,\s*[^,]+,\s*['\"]root['\"]\)" ${filename}; then
    echo "The file ${filename} attempts to use the 'root' group - use '0' instead for UNIX compatibility"
    exit 1
  fi
done || EXIT=1

# Check that no removed deprecated techniques come back (via erroneous merges, for example)
${REPOSITORY_PATH}/scripts/technique-files -d "${REPOSITORY_PATH}/techniques" | while read name
do

  # Get relative technique version/name path
  TECHNIQUE=$(echo ${name} | sed "s%${REPOSITORY_PATH}/techniques/%%")

  if ! egrep "^${TECHNIQUE}" ${REPOSITORY_PATH}/maintained-techniques > /dev/null; then
    echo "Unexpected technique version ${TECHNIQUE} found. Maybe it is deprecated but has come back via a merge. Please remove it, or if it's a new version, add it to maintained-techniques."
    exit 1
  fi
done || EXIT=1

# Check that all technique versions listed as maintained are indeed present
cat ${REPOSITORY_PATH}/maintained-techniques | while read name
do

  # Skip comments
  if echo ${name} | egrep "^[   ]*#" > /dev/null; then continue; fi

  if [ ! -d ${REPOSITORY_PATH}/techniques/${name} ]; then
    echo "Supposedly maintained technique version ${name} is missing"
    exit 1
  fi
done || EXIT=1

# Check that there is an empty line after each endif
${REPOSITORY_PATH}/scripts/technique-files -f '*.cf' -f '*.st' "${REPOSITORY_PATH}" | while read filename
do
  if grep -n -A1 "^[[:space:]]*&endif&[[:space:]]*$" "${filename}" | grep -E -B1 -- "^[[:digit:]]+-.+"; then
    echo "&endif& not followed by an empty line in ${filename}"
    exit 1
  fi
done || EXIT=1

# Check that .cf files do not contain stringtemplate variables ( lines beginning with & or StringTemplate iterators )
${REPOSITORY_PATH}/scripts/technique-files -f '*.cf' "${REPOSITORY_PATH}/techniques/" | while read filename
do
  if grep -E '^\s*&|&[a-zA-Z_]&' "${filename}" > /dev/null; then
    echo "Stringtemplate variable in .cf file ${filename}"
    exit 1
  fi
done || EXIT=1

# Check that there are non non-breaking spaces in files
# See http://www.rudder-project.org/redmine/issues/7622 - these cause regex failures.
${REPOSITORY_PATH}/scripts/technique-files -p "${REPOSITORY_PATH}" | while read filename
do
  if grep -n -P '\xA0' "${filename}" > /dev/null; then
    echo "Non-breakable space in ${filename}:"
	echo "---------------------------------------------------------------------"
	grep -Hn -P '\xA0' "${filename}"
	grep -P '\xA0' "${filename}" | od -t x2c | grep -A1 --color -i a0
	echo "---------------------------------------------------------------------"
    exit 1
  fi
done || EXIT=1

# don't run cf-promises tests in qa-test context
if [ -z $QA_TEST ]; then
  # Check that .cf files in techniques do not contains syntax error
  # NOTE: We can't check templated files for now
  ${REPOSITORY_PATH}/scripts/technique-files -i -f '*.cf' "${REPOSITORY_PATH}/techniques/" | while read filename
  do
    echo "${filename}"
    if ! cf-promises "${filename}"; then
      echo "Syntax error in ${filename}"
      exit 1
    fi
  done || EXIT=1

  # Check that initial policies do not contains syntax error
  rm -f "${REPOSITORY_PATH}/initial-promises/node-server/distributePolicy/1.0/nodeslist.json.cf"
  # Avoid automated full check based on promises.cf file name...
  mv "${REPOSITORY_PATH}/initial-promises/node-server/promises.cf" "${REPOSITORY_PATH}/initial-promises/node-server/promises2.cf" || true
  ${REPOSITORY_PATH}/scripts/technique-files -i -f '*.cf' "${REPOSITORY_PATH}/initial-promises/" | while read filename
  do
    echo "${filename}"
    # Pass list_compatible_inputs_ok to skip check for executable existence
    if ! cf-promises -D  list_compatible_inputs_ok "${filename}"; then
      echo "Syntax error in ${filename}"
      exit 1
    fi
  done || EXIT=1
  # Put the file back in place
  mv "${REPOSITORY_PATH}/initial-promises/node-server/promises2.cf" "${REPOSITORY_PATH}/initial-promises/node-server/promises.cf" || true

  # Check that bootstrap policies do not contains syntax error
  ${REPOSITORY_PATH}/scripts/technique-files -i -f '*.cf' "${REPOSITORY_PATH}/bootstrap-promises/" | while read filename
  do
    echo "${filename}"
    if ! cf-promises "${filename}"; then
      echo "Syntax error in ${filename}"
      exit 1
    fi
  done || EXIT=1
fi

if [ ${EXIT} -eq 0 ]; then
  echo "This repository seems clean"
else
  echo "There are errors, please correct them"
  exit ${EXIT}
fi

