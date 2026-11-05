/// A user, exactly as the server stores it in the "user" table.
/// The password is not part of this model: the server only sends the hash to the
/// database, never to the client.
class User {
  const User({required this.id, required this.username, required this.email});

  final int id;
  final String username;
  final String email;

  factory User.fromJson(Map<String, dynamic> json) => User(
    id: json['id'] as int,
    username: json['username'] as String,
    email: json['email'] as String,
  );
}
