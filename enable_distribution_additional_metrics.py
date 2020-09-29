#!/usr/bin/env python3


# This script makes an API call to the AWS CloudFront service to enable 
# additional metrics on a CDN distribution.
#
# This API is not officially available, it is not documented, and therefore not
# included in the AWS SDK.



# Copyright 2010-2019 Amazon.com, Inc. or its affiliates. All Rights Reserved.
# Modifications copyright (C) 2020 Quortex
#
# This file is licensed under the Apache License, Version 2.0 (the "License").
# You may not use this file except in compliance with the License. A copy of the
# License is located at
#
# http://aws.amazon.com/apache2.0/
#
# This file is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS
# OF ANY KIND, either express or implied. See the License for the specific
# language governing permissions and limitations under the License.
#
# Code inspired by the example from:
# https://docs.aws.amazon.com/general/latest/gr/sigv4-signed-request-examples.html

import argparse
import sys, os, base64, datetime, hashlib, hmac, urllib
import requests # pip install requests

from configparser import ConfigParser
from configparser import ParsingError
from configparser import NoOptionError
from configparser import NoSectionError


# ************* PARSE ARGUMENTS *************

parser = argparse.ArgumentParser(description="Enable additional metrics on the AWS CloudFront distribution")
parser.add_argument("distribution_id", help="id of the CloudFront distribution") 
parser.add_argument("enabled", choices=['true', 'false'], help="\"true\" if the additional metrics should be enabled, \"false\" otherwise") 
args = parser.parse_args()


# ************* REQUEST VALUES *************
method = 'POST'
service = 'cloudfront'
host = 'cloudfront.amazonaws.com'
region = 'us-east-1'
endpoint = 'https://cloudfront.amazonaws.com/2019-03-26/distributions/' + args.distribution_id + '/monitoring-subscription'
uri = '/2019-03-26/distributions/' + args.distribution_id + '/monitoring-subscription'
action = 'updateMonitoringSubscription'

request_body =  '''<?xml version="1.0" encoding="UTF-8"?>
<MonitoringSubscriptionConfig xmlns=\"http://cloudfront.amazonaws.com/doc/2019-03-26/\">
    <RealtimeMetricsSubscriptionConfig>
        <SubscriptionStatus>{}</SubscriptionStatus>
    </RealtimeMetricsSubscriptionConfig>
</MonitoringSubscriptionConfig>
'''.format("Enabled" if args.enabled == "true" else "Disabled")


# Key derivation functions. See:
# http://docs.aws.amazon.com/general/latest/gr/signature-v4-examples.html#signature-v4-examples-python
def sign(key, msg):
    return hmac.new(key, msg.encode('utf-8'), hashlib.sha256).digest()

def getSignatureKey(key, dateStamp, regionName, serviceName):
    kDate = sign(('AWS4' + key).encode('utf-8'), dateStamp)
    kRegion = sign(kDate, regionName)
    kService = sign(kRegion, serviceName)
    kSigning = sign(kService, 'aws4_request')
    return kSigning

# Read AWS access key from env. variables or configuration file. Best practice is NOT
# to embed credentials in code.

def get_profile_credentials(profile_name):
    from os import path
    config = ConfigParser()
    config.read([path.join(path.expanduser("~"),'.aws/credentials')])
    try:
        aws_access_key_id = config.get(profile_name, 'aws_access_key_id')
        aws_secret_access_key = config.get(profile_name, 'aws_secret_access_key')
    except ParsingError:
        print('Error parsing config file')
        raise
    except (NoSectionError, NoOptionError):
        try:
            aws_access_key_id = config.get('default', 'aws_access_key_id')
            aws_secret_access_key = config.get('default', 'aws_secret_access_key')
        except (NoSectionError, NoOptionError):
            print('Unable to find valid AWS credentials')
            raise
    return aws_access_key_id, aws_secret_access_key

access_key, secret_key = get_profile_credentials('default')
if access_key is None or secret_key is None:
    print('No access key is available.')
    sys.exit()

# Create a date for headers and the credential string
t = datetime.datetime.utcnow()
amz_date = t.strftime('%Y%m%dT%H%M%SZ') # Format date as YYYYMMDD'T'HHMMSS'Z'
datestamp = t.strftime('%Y%m%d') # Date w/o time, used in credential scope


# ************* TASK 1: CREATE A CANONICAL REQUEST *************
# http://docs.aws.amazon.com/general/latest/gr/sigv4-create-canonical-request.html

canonical_uri = uri
canonical_headers = 'host:' + host + '\n'
signed_headers = 'host'

# Match the algorithm to the hashing algorithm you use, either SHA-1 or SHA-256 (recommended)
algorithm = 'AWS4-HMAC-SHA256'
credential_scope = datestamp + '/' + region + '/' + service + '/' + 'aws4_request'

# Create the canonical query string.
canonical_querystring = 'Action=' + action +'&Version=2019-03-26'
canonical_querystring += '&X-Amz-Algorithm=AWS4-HMAC-SHA256'
canonical_querystring += '&X-Amz-Credential=' + urllib.parse.quote_plus(access_key + '/' + credential_scope)
canonical_querystring += '&X-Amz-Date=' + amz_date
canonical_querystring += '&X-Amz-Expires=30'
canonical_querystring += '&X-Amz-SignedHeaders=' + signed_headers

# Create payload hash. 
payload_hash = hashlib.sha256(request_body.encode('utf-8')).hexdigest()

# Combine elements to create canonical request
canonical_request = method + '\n' + canonical_uri + '\n' + canonical_querystring + '\n' + canonical_headers + '\n' + signed_headers + '\n' + payload_hash


# ************* TASK 2: CREATE THE STRING TO SIGN*************
string_to_sign = algorithm + '\n' +  amz_date + '\n' +  credential_scope + '\n' +  hashlib.sha256(canonical_request.encode('utf-8')).hexdigest()


# ************* TASK 3: CALCULATE THE SIGNATURE *************
# Create the signing key
signing_key = getSignatureKey(secret_key, datestamp, region, service)

# Sign the string_to_sign using the signing_key
signature = hmac.new(signing_key, (string_to_sign).encode("utf-8"), hashlib.sha256).hexdigest()


# ************* TASK 4: ADD SIGNING INFORMATION TO THE REQUEST *************
canonical_querystring += '&X-Amz-Signature=' + signature


# ************* SEND THE REQUEST *************
# The 'host' header is added automatically by the Python 'request' lib. But it must exist as a header in the request.
request_url = endpoint + "?" + canonical_querystring

r = requests.post(request_url, data=request_body)

if not r.ok:
    print('Request URL = ' + request_url, file=sys.stderr)
    print('Response code: %d' % r.status_code, file=sys.stderr)
    print('Response data:')
    print(r.text, file=sys.stderr)
    sys.exit(1)
else:
    print('Successfully enabled additional metrics on CDN distribution ' + args.distribution_id)
