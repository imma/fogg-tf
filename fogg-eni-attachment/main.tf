data "aws_network_interface" "network" {
  filter {
    name   = "availability-zone"
    values = ["${var.instance_az}"]
  }

  filter {
    name   = "tag:Name"
    values = ["${var.eni_name}"]
  }
}

resource "aws_network_interface_attachment" "network" {
  instance_id          = "${var.instance_id}"
  network_interface_id = "${data.aws_network_interface.network.id}"
  device_index         = 1
  count                = "${var.mcount}"
}

resource "aws_eip" "network" {
  vpc   = true
  count = "${var.mcount}"
}

resource "aws_eip_association" "network" {
  network_interface_id = "${element(aws_network_interface.network.*.id,count.index)}"
  allocation_id        = "${element(aws_eip.network.*.id,count.index)}"
  count                = "${var.interface_count*var.want_eip}"
}
