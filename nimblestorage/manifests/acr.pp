class nimblestorage::acr{
  require nimblestorage::volume
  create_resources(nimble_acr, hiera('access_control', { }), { transport => hiera_hash('transport'), config => hiera('iscsiadm.config'), mp => hiera('multipath.config') })
}